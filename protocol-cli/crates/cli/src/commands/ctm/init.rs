use clap::Parser;
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_cli_common::{
    forge::{ForgeArgs, ForgeRunner},
    logger,
};
use protocol_cli_config::forge_interface::deploy_ctm::output::DeployCTMOutput;
use protocol_cli_types::VMOption;
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::commands::ctm::accept_ownership::{accept_ownership, CtmAcceptOwnershipInput};
use crate::commands::ctm::deploy::{deploy, CtmDeployInput};
use crate::commands::hub::register_ctm::{register_ctm, RegisterCtmInput};
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext, SenderAuth};
use crate::utils::paths;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmInitArgs {
    /// Bridgehub proxy address
    #[clap(long)]
    pub bridgehub: Address,

    /// Owner address for the deployed contracts (default: sender)
    #[clap(long)]
    pub owner: Option<Address>,

    /// Owner private key (required if owner != sender)
    #[clap(long, alias = "owner-pk")]
    pub owner_private_key: Option<H256>,

    /// Bridgehub governance owner private key for accepting ownership (required when reuse_gov_and_admin=true, as it uses hub's governance)
    #[clap(long, alias = "bridgehub-owner-pk")]
    pub bridgehub_owner_private_key: Option<H256>,

    /// Bridgehub admin private key for registering CTM (default: uses governance owner key)
    #[clap(long, alias = "bridgehub-admin-pk")]
    pub bridgehub_admin_private_key: Option<H256>,

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
    /// VM type: zksyncos (default) or eravm
    #[clap(long, default_value = "zksyncos", help_heading = "Dev options")]
    pub vm_type: String,
    /// Reuse governance and admin contracts from hub (default: true)
    #[clap(long, default_value_t = true, help_heading = "Dev options")]
    pub reuse_gov_and_admin: bool,
    /// Use testnet verifier (default: true)
    #[clap(long, default_value_t = true, help_heading = "Dev options")]
    pub with_testnet_verifier: bool,
    /// Enable support for legacy bridge testing (default: false)
    #[clap(long, default_value_t = false, help_heading = "Dev options")]
    pub with_legacy_bridge: bool,
}

pub async fn run(args: CtmInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let vm_type = match args.vm_type.to_lowercase().as_str() {
        "eravm" | "era" => VMOption::EraVM,
        "zksyncos" | "zksync" | "zksync-os" => VMOption::ZKSyncOsVM,
        _ => anyhow::bail!("Invalid VM type '{}'. Use 'zksyncos' or 'eravm'", args.vm_type),
    };

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.dev, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);

    // Resolve owner auth for accept_ownership and register steps
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

    // Resolve governance owner auth for accept_ownership step
    // When reuse_gov_and_admin=true, this must be the HUB's governance owner
    let bridgehub_owner_auth = if let Some(gov_pk) = args.bridgehub_owner_private_key {
        let local_wallet = LocalWallet::from_bytes(gov_pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid governance owner private key: {}", e))?;
        logger::info(format!(
            "Governance owner (for accepting ownership): {:#x}",
            local_wallet.address()
        ));
        SenderAuth::PrivateKey(gov_pk)
    } else if args.reuse_gov_and_admin {
        anyhow::bail!(
            "--bridgehub-owner-private-key is required when --reuse-gov-and-admin=true \
            (the hub's governance owner must accept ownership)"
        );
    } else {
        // When not reusing, the new owner is also the governance owner
        owner_auth.clone()
    };

    // Resolve bridgehub admin auth for register_ctm step (defaults to governance owner)
    let bridgehub_admin_auth = if let Some(admin_pk) = args.bridgehub_admin_private_key {
        let local_wallet = LocalWallet::from_bytes(admin_pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid bridgehub admin private key: {}", e))?;
        logger::info(format!(
            "Bridgehub admin (for CTM registration): {:#x}",
            local_wallet.address()
        ));
        SenderAuth::PrivateKey(admin_pk)
    } else {
        // Default to governance owner auth
        bridgehub_owner_auth.clone()
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

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());

    // Step 1: Deploy CTM contracts (as sender)
    logger::info(format!("Deploying CTM contracts as sender: {:#x}", sender));
    logger::info(format!("Owner will be: {:#x}", owner));
    logger::info(format!("Bridgehub: {:#x}", args.bridgehub));

    let deploy_input = CtmDeployInput {
        bridgehub: args.bridgehub,
        owner,
        vm_type,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
    };

    let deploy_output = {
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

    let deployed = &deploy_output.deployed_addresses;
    let ctm_proxy = deployed.state_transition.state_transition_proxy_addr;
    let governance = deployed.governance_addr;
    let chain_admin = deployed.chain_admin;

    // Step 2: Accept ownership of deployed CTM contracts (as governance owner)
    logger::info("Accepting ownership of CTM...");

    let accept_input = CtmAcceptOwnershipInput {
        ctm_proxy,
        governance,
        chain_admin,
    };

    {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &bridgehub_owner_auth,
        };
        accept_ownership(&mut ctx, &accept_input).await?;
    }

    // Step 3: Register CTM on Bridgehub (as bridgehub admin)
    logger::info("Registering CTM on Bridgehub...");

    let register_input = RegisterCtmInput {
        bridgehub: args.bridgehub,
        ctm_proxy,
    };

    {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &bridgehub_admin_auth,
        };
        register_ctm(&mut ctx, &register_input)?;
    }

    // Build and output plan
    let plan = build_plan(&deploy_input, &deploy_output, &runner);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    if is_simulation {
        logger::outro("CTM init simulation complete (no on-chain changes)");
    } else {
        logger::outro("CTM initialized");
    }

    drop(execution_mode);

    Ok(())
}

fn build_plan(input: &CtmDeployInput, output: &DeployCTMOutput, runner: &ForgeRunner) -> serde_json::Value {
    let deployed = &output.deployed_addresses;

    let mut transactions = Vec::new();
    for run in runner.runs() {
        if let Some(txs) = run.transactions() {
            for tx in txs {
                transactions.push(tx.clone());
            }
        }
    }

    json!({
        "command": "ctm.init",
        "config": {
            "bridgehub": format!("{:#x}", input.bridgehub),
            "vm_type": format!("{:?}", input.vm_type),
            "reuse_gov_and_admin": input.reuse_gov_and_admin,
            "with_testnet_verifier": input.with_testnet_verifier,
            "with_legacy_bridge": input.with_legacy_bridge,
        },
        "transactions": transactions,
        "artifacts": {
            "state_transition": {
                "proxy_addr": format!("{:#x}", deployed.state_transition.state_transition_proxy_addr),
                "verifier_addr": format!("{:#x}", deployed.state_transition.verifier_addr),
                "genesis_upgrade_addr": format!("{:#x}", deployed.state_transition.genesis_upgrade_addr),
                "default_upgrade_addr": format!("{:#x}", deployed.state_transition.default_upgrade_addr),
                "bytecodes_supplier_addr": format!("{:#x}", deployed.state_transition.bytecodes_supplier_addr),
            },
            "governance_addr": format!("{:#x}", deployed.governance_addr),
            "chain_admin_addr": format!("{:#x}", deployed.chain_admin),
            "validator_timelock_addr": format!("{:#x}", deployed.validator_timelock_addr),
            "rollup_l1_da_validator_addr": format!("{:#x}", deployed.rollup_l1_da_validator_addr),
            "no_da_validium_l1_validator_addr": format!("{:#x}", deployed.no_da_validium_l1_validator_addr),
            "blobs_zksync_os_l1_da_validator_addr": format!("{:#x}", deployed.blobs_zksync_os_l1_da_validator_addr.unwrap_or(Address::zero())),
            "server_notifier_proxy_addr": format!("{:#x}", deployed.server_notifier_proxy_addr),
            "diamond_cut_data": output.contracts_config.diamond_cut_data.clone(),
        },
    })
}
