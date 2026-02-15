use std::path::PathBuf;

use clap::Parser;
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use crate::common::{
    forge::{resolve_execution, ExecutionMode, ForgeArgs, ForgeContext, ForgeRunner, SenderAuth},
    logger,
};
use crate::config::forge_interface::deploy_ecosystem::output::DeployL1CoreContractsOutput;
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::commands::hub::accept_ownership::{accept_ownership, AcceptOwnershipInput};
use crate::commands::hub::deploy::{deploy, DeployInput};
use crate::utils::paths;

/// Input parameters for hub init.
#[derive(Debug, Clone)]
pub struct HubInitInput {
    pub owner: Address,
    pub era_chain_id: u64,
    pub with_legacy_bridge: bool,
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}

/// Initialize hub: deploy contracts and accept ownership.
/// Returns the deployment output containing all deployed addresses.
pub async fn hub_init(
    ctx: &mut ForgeContext<'_>,
    input: &HubInitInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    // Step 1: Deploy hub contracts
    logger::info("Deploying hub contracts...");
    let deploy_input = DeployInput {
        owner: input.owner,
        era_chain_id: input.era_chain_id,
        with_legacy_bridge: input.with_legacy_bridge,
        create2_factory_addr: input.create2_factory_addr,
        create2_factory_salt: input.create2_factory_salt,
    };
    let output = deploy(ctx, &deploy_input)?;

    // Step 2: Accept ownership of deployed contracts
    logger::info("Accepting ownership of hub contracts...");
    let deployed = &output.deployed_addresses;
    let accept_input = AcceptOwnershipInput {
        bridgehub: deployed.bridgehub.bridgehub_proxy_addr,
        asset_router: deployed.bridges.shared_bridge_proxy_addr,
        stm_deployment_tracker: deployed.bridgehub.ctm_deployment_tracker_proxy_addr,
        chain_asset_handler: Some(deployed.bridgehub.chain_asset_handler_proxy_addr),
        governance: deployed.governance_addr,
        chain_admin: deployed.chain_admin,
    };
    accept_ownership(ctx, &accept_input).await?;

    Ok(output)
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubInitArgs {
    #[clap(long, help = "Owner address for the deployed contracts (default: sender)")]
    pub owner: Option<Address>,
    #[clap(long, alias = "owner-pk", help = "Owner private key")]
    pub owner_private_key: Option<H256>,

    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, help = "Sender address")]
    pub sender: Option<Address>,
    #[clap(long, visible_alias = "pk", help = "Sender private key")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Simulate against anvil fork (no on-chain changes)")]
    pub simulate: bool,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,

    // Create2 factory options
    #[clap(long, help = "CREATE2 factory address (if already deployed)", help_heading = "CREATE2 options")]
    pub create2_factory_addr: Option<Address>,
    #[clap(long, help = "CREATE2 factory salt (random by default)", help_heading = "CREATE2 options")]
    pub create2_factory_salt: Option<H256>,

    // Options
    #[clap(long, help = "Enable support for legacy bridge testing", default_value_t = false)]
    pub with_legacy_bridge: bool,
    #[clap(long, help = "Era chain ID", default_value_t = 270)]
    pub era_chain_id: u64,

    // Output
    #[clap(long, help = "Write full JSON output to file", help_heading = "Output")]
    pub out: Option<PathBuf>,
}

pub async fn run(args: HubInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);

    // Resolve owner auth for accept_ownership step
    let owner_auth = if owner == sender {
        // Owner is the same as sender, reuse the same auth
        sender_auth.clone()
    } else {
        // Owner is different from sender, need owner's private key
        let owner_pk = args.owner_private_key.ok_or_else(|| {
            anyhow::anyhow!(
                "Owner ({:#x}) differs from sender ({:#x}), --owner-private-key is required",
                owner,
                sender
            )
        })?;
        let local_wallet = LocalWallet::from_bytes(owner_pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid owner private key: {}", e))?;
        if local_wallet.address() != owner {
            anyhow::bail!(
                "Owner private key does not match owner address: got {:#x}, want {:#x}",
                local_wallet.address(),
                owner
            );
        }
        SenderAuth::PrivateKey(owner_pk)
    };

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    if is_simulation {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
    }

    // In simulation mode, forge targets the anvil fork instead of the original RPC.
    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);

    let mut runner = ForgeRunner::new();

    // Step 1: Deploy hub contracts (as sender)
    logger::info(format!("Deploying hub contracts as sender: {:#x}", sender));
    logger::info(format!("Owner will be: {:#x}", owner));

    let deploy_input = DeployInput {
        owner,
        era_chain_id: args.era_chain_id,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    let output = {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &sender_auth,
        };
        deploy(&mut ctx, &deploy_input)?
    };

    // Step 2: Accept ownership of deployed contracts (as owner)
    logger::info(format!("Accepting ownership as owner: {:#x}", owner));
    let deployed = &output.deployed_addresses;

    let accept_input = AcceptOwnershipInput {
        bridgehub: deployed.bridgehub.bridgehub_proxy_addr,
        asset_router: deployed.bridges.shared_bridge_proxy_addr,
        stm_deployment_tracker: deployed.bridgehub.ctm_deployment_tracker_proxy_addr,
        chain_asset_handler: Some(deployed.bridgehub.chain_asset_handler_proxy_addr),
        governance: deployed.governance_addr,
        chain_admin: deployed.chain_admin,
    };

    {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &owner_auth,
        };
        accept_ownership(&mut ctx, &accept_input).await?;
    }

    let bridgehub_addr = output.deployed_addresses.bridgehub.bridgehub_proxy_addr;

    if let Some(out_path) = &args.out {
        let result = build_output(&output, &runner);
        let result_json = serde_json::to_string_pretty(&result)?;
        std::fs::write(out_path, &result_json)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    if is_simulation {
        logger::outro(format!("Hub init simulation complete — Bridgehub Proxy: {:#x}", bridgehub_addr));
    } else {
        logger::outro(format!("Bridgehub Proxy deployed at: {:#x}", bridgehub_addr));
    }

    drop(execution_mode);

    Ok(())
}

fn build_output(output: &DeployL1CoreContractsOutput, runner: &ForgeRunner) -> serde_json::Value {
    let deployed = &output.deployed_addresses;

    let runs: Vec<_> = runner.runs().iter().map(|r| json!({
        "script": r.script.display().to_string(),
        "run": r.payload,
    })).collect();

    json!({
        "command": "hub.init",
        "runs": runs,
        "output": {
            "create2_factory_addr": format!("{:#x}", output.contracts.create2_factory_addr),
            "create2_factory_salt": format!("{:#x}", output.contracts.create2_factory_salt),
            "core_ecosystem_contracts": {
                "bridgehub_proxy_addr": format!("{:#x}", deployed.bridgehub.bridgehub_proxy_addr),
                "message_root_proxy_addr": format!("{:#x}", deployed.bridgehub.message_root_proxy_addr),
                "transparent_proxy_admin_addr": format!("{:#x}", deployed.transparent_proxy_admin_addr),
                "stm_deployment_tracker_proxy_addr": format!("{:#x}", deployed.bridgehub.ctm_deployment_tracker_proxy_addr),
                "native_token_vault_addr": format!("{:#x}", deployed.native_token_vault_addr),
                "chain_asset_handler_proxy_addr": format!("{:#x}", deployed.bridgehub.chain_asset_handler_proxy_addr),
            },
            "bridges": {
                "erc20": {
                    "l1_address": format!("{:#x}", deployed.bridges.erc20_bridge_proxy_addr),
                },
                "shared": {
                    "l1_address": format!("{:#x}", deployed.bridges.shared_bridge_proxy_addr),
                },
                "l1_nullifier_addr": format!("{:#x}", deployed.bridges.l1_nullifier_proxy_addr),
            },
            "l1": {
                "governance_addr": format!("{:#x}", deployed.governance_addr),
                "chain_admin_addr": format!("{:#x}", deployed.chain_admin),
                "access_control_restriction_addr": format!("{:#x}", deployed.access_control_restriction_addr),
            },
        },
    })
}
