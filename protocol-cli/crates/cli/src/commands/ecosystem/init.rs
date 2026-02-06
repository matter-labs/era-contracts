use clap::Parser;
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_cli_common::{
    forge::{ForgeArgs, ForgeRunner},
    logger,
};
use protocol_cli_config::forge_interface::deploy_ecosystem::output::DeployL1CoreContractsOutput;
use protocol_cli_types::VMOption;
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::commands::ctm::init::{ctm_init, CtmInitInput, CtmInitOutput};
use crate::commands::hub::init::{hub_init, HubInitInput};
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext, SenderAuth};
use crate::utils::paths;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct EcosystemInitArgs {
    /// Owner address for the deployed contracts (default: sender)
    #[clap(long)]
    pub owner: Option<Address>,

    /// Owner private key (required if owner != sender)
    #[clap(long, alias = "owner-pk")]
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

    // Dev options
    #[clap(long, help = "Use dev defaults", default_value_t = false, help_heading = "Dev options")]
    pub dev: bool,
    #[clap(long, help = "Era chain ID", default_value_t = 270, help_heading = "Dev options")]
    pub era_chain_id: u64,
    /// VM type: zksyncos (default) or eravm
    #[clap(long, default_value = "zksyncos", help_heading = "Dev options")]
    pub vm_type: String,
    /// Use testnet verifier (default: true)
    #[clap(long, default_value_t = true, help_heading = "Dev options")]
    pub with_testnet_verifier: bool,
    /// Enable support for legacy bridge testing (default: false)
    #[clap(long, default_value_t = false, help_heading = "Dev options")]
    pub with_legacy_bridge: bool,
}

/// Input parameters for ecosystem init.
#[derive(Debug, Clone)]
pub struct EcosystemInitInput {
    pub owner: Address,
    pub era_chain_id: u64,
    pub vm_type: VMOption,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
}

/// Output from ecosystem init.
#[derive(Debug, Clone)]
pub struct EcosystemInitOutput {
    pub hub_output: DeployL1CoreContractsOutput,
    pub ctm_output: CtmInitOutput,
}

pub async fn run(args: EcosystemInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let vm_type = match args.vm_type.to_lowercase().as_str() {
        "eravm" | "era" => VMOption::EraVM,
        "zksyncos" | "zksync" | "zksync-os" => VMOption::ZKSyncOsVM,
        _ => anyhow::bail!("Invalid VM type '{}'. Use 'zksyncos' or 'eravm'", args.vm_type),
    };

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.dev, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);

    // Resolve owner auth
    let owner_auth = if owner == sender {
        sender_auth.clone()
    } else {
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

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);
    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());

    logger::info("Initializing ecosystem...");
    logger::info(format!("Sender: {:#x}", sender));
    logger::info(format!("Owner: {:#x}", owner));

    // Step 1: Initialize hub (deploy + accept ownership)
    logger::step("Initializing hub...");
    let hub_input = HubInitInput {
        owner,
        era_chain_id: args.era_chain_id,
        with_legacy_bridge: args.with_legacy_bridge,
    };

    let hub_output = {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &owner_auth, // Owner deploys and accepts
        };
        hub_init(&mut ctx, &hub_input).await?
    };

    let bridgehub = hub_output.deployed_addresses.bridgehub.bridgehub_proxy_addr;
    logger::info(format!("Hub initialized. Bridgehub: {:#x}", bridgehub));

    // Step 2: Initialize CTM (deploy + accept ownership + register)
    // When reuse_gov_and_admin=true, the CTM uses the hub's governance and admin
    logger::step("Initializing CTM...");
    let ctm_input = CtmInitInput {
        bridgehub,
        owner,
        vm_type,
        reuse_gov_and_admin: true, // Always reuse in ecosystem init
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
    };

    let ctm_output = ctm_init(
        shell,
        foundry_scripts_path.as_path(),
        &mut runner,
        &args.forge_args.script,
        effective_rpc,
        &ctm_input,
        &owner_auth, // Deploy as owner
        &owner_auth, // Accept ownership as owner (uses hub's governance)
        &owner_auth, // Register as owner (uses hub's chain_admin)
    )
    .await?;

    logger::info(format!("CTM initialized. CTM proxy: {:#x}", ctm_output.ctm_proxy));

    // Build and output plan
    let plan = build_plan(&hub_output, &ctm_output, &runner);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    if is_simulation {
        logger::outro("Ecosystem init simulation complete (no on-chain changes)");
    } else {
        logger::outro("Ecosystem initialized");
    }

    drop(execution_mode);

    Ok(())
}

fn build_plan(
    hub_output: &DeployL1CoreContractsOutput,
    ctm_output: &CtmInitOutput,
    runner: &ForgeRunner,
) -> serde_json::Value {
    let hub = &hub_output.deployed_addresses;
    let ctm = &ctm_output.deploy_output.deployed_addresses;

    let mut transactions = Vec::new();
    for run in runner.runs() {
        if let Some(txs) = run.transactions() {
            for tx in txs {
                transactions.push(tx.clone());
            }
        }
    }

    json!({
        "command": "ecosystem.init",
        "transactions": transactions,
        "output": {
            "hub": {
                "create2_factory_addr": format!("{:#x}", hub_output.contracts.create2_factory_addr),
                "bridgehub_proxy_addr": format!("{:#x}", hub.bridgehub.bridgehub_proxy_addr),
                "message_root_proxy_addr": format!("{:#x}", hub.bridgehub.message_root_proxy_addr),
                "transparent_proxy_admin_addr": format!("{:#x}", hub.transparent_proxy_admin_addr),
                "stm_deployment_tracker_proxy_addr": format!("{:#x}", hub.bridgehub.ctm_deployment_tracker_proxy_addr),
                "native_token_vault_addr": format!("{:#x}", hub.native_token_vault_addr),
                "chain_asset_handler_proxy_addr": format!("{:#x}", hub.bridgehub.chain_asset_handler_proxy_addr),
                "shared_bridge_proxy_addr": format!("{:#x}", hub.bridges.shared_bridge_proxy_addr),
                "erc20_bridge_proxy_addr": format!("{:#x}", hub.bridges.erc20_bridge_proxy_addr),
                "l1_nullifier_proxy_addr": format!("{:#x}", hub.bridges.l1_nullifier_proxy_addr),
                "governance_addr": format!("{:#x}", hub.governance_addr),
                "chain_admin_addr": format!("{:#x}", hub.chain_admin),
            },
            "ctm": {
                "state_transition_proxy_addr": format!("{:#x}", ctm.state_transition.state_transition_proxy_addr),
                "verifier_addr": format!("{:#x}", ctm.state_transition.verifier_addr),
                "genesis_upgrade_addr": format!("{:#x}", ctm.state_transition.genesis_upgrade_addr),
                "default_upgrade_addr": format!("{:#x}", ctm.state_transition.default_upgrade_addr),
                "validator_timelock_addr": format!("{:#x}", ctm.validator_timelock_addr),
                "rollup_l1_da_validator_addr": format!("{:#x}", ctm.rollup_l1_da_validator_addr),
                "no_da_validium_l1_validator_addr": format!("{:#x}", ctm.no_da_validium_l1_validator_addr),
            },
        },
    })
}
