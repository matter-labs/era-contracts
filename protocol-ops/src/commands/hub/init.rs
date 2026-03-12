use std::path::PathBuf;

use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::commands::hub::accept_ownership::{accept_ownership, AcceptOwnershipInput};
use crate::commands::hub::deploy::{deploy, DeployInput};
use crate::commands::output::CommandEnvelope;
use crate::common::{
    forge::{
        resolve_execution, resolve_owner_auth, ExecutionMode, ForgeArgs, ForgeContext, ForgeRunner,
    },
    logger,
};
use crate::config::forge_interface::deploy_ecosystem::output::DeployL1CoreContractsOutput;
use crate::common::paths;

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubInitArgs {
    // Signers
    /// Sender address
    #[clap(long, help_heading = "Signers")]
    pub sender: Option<Address>,
    /// Owner address (default: sender)
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    // Auth
    /// Sender private key
    #[clap(long, visible_alias = "pk", help_heading = "Auth")]
    pub private_key: Option<H256>,
    /// Owner private key
    #[clap(long, visible_alias = "owner-pk", help_heading = "Auth")]
    pub owner_private_key: Option<H256>,

    // Execution
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545", help_heading = "Execution")]
    pub l1_rpc_url: String,
    /// Simulate against anvil fork
    #[clap(long, help_heading = "Execution")]
    pub simulate: bool,

    // Output
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

    // Advanced input
    /// Era chain ID
    #[clap(long, default_value_t = 270, help_heading = "Advanced input")]
    pub era_chain_id: u64,
    /// Enable legacy bridge testing
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true",
           help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
    /// CREATE2 factory address
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_addr: Option<Address>,
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<H256>,

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: HubInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);
    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    let owner_auth = resolve_owner_auth(
        owner,
        args.owner_private_key,
        sender,
        &sender_auth,
        is_simulation,
    )?;

    if is_simulation {
        logger::info(format!("Simulation mode: forking {} via anvil", args.l1_rpc_url));
    }
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

    let mut ctx = ForgeContext {
        shell,
        foundry_scripts_path: foundry_scripts_path.as_path(),
        runner: &mut runner,
        forge_args: &args.forge_args.script,
        l1_rpc_url: effective_rpc,
        auth: &sender_auth,
    };
    let output = deploy(&mut ctx, &deploy_input)?;

    // Step 2: Accept ownership (as owner)
    logger::info(format!("Accepting ownership as owner: {:#x}", owner));
    let deployed = &output.deployed_addresses;
    let accept_input = AcceptOwnershipInput {
        bridgehub: deployed.bridgehub.bridgehub_proxy_addr,
        governance: deployed.governance_addr,
        chain_admin: deployed.chain_admin,
    };
    ctx.auth = &owner_auth;
    accept_ownership(&mut ctx, &accept_input).await?;

    let bridgehub_addr = output.deployed_addresses.bridgehub.bridgehub_proxy_addr;

    if let Some(out_path) = &args.out {
        let input_echo = HubInitInputEcho {
            sender,
            owner,
            l1_rpc_url: args.l1_rpc_url.clone(),
            era_chain_id: args.era_chain_id,
            with_legacy_bridge: args.with_legacy_bridge,
            simulate: args.simulate,
        };
        let output_data = HubInitOutputData::from_deploy_output(&output);
        let envelope = CommandEnvelope::new("hub.init", input_echo, output_data, &runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    if is_simulation {
        logger::outro(format!(
            "Hub init simulation complete — Bridgehub Proxy: {:#x}",
            bridgehub_addr
        ));
    } else {
        logger::outro(format!("Bridgehub Proxy deployed at: {:#x}", bridgehub_addr));
    }

    drop(execution_mode);
    Ok(())
}

// ── Library function (for programmatic use) ─────────────────────────────────

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
pub async fn hub_init(
    ctx: &mut ForgeContext<'_>,
    input: &HubInitInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    logger::info("Deploying hub contracts...");
    let deploy_input = DeployInput {
        owner: input.owner,
        era_chain_id: input.era_chain_id,
        with_legacy_bridge: input.with_legacy_bridge,
        create2_factory_addr: input.create2_factory_addr,
        create2_factory_salt: input.create2_factory_salt,
    };
    let output = deploy(ctx, &deploy_input)?;

    logger::info("Accepting ownership of hub contracts...");
    let deployed = &output.deployed_addresses;
    let accept_input = AcceptOwnershipInput {
        bridgehub: deployed.bridgehub.bridgehub_proxy_addr,
        governance: deployed.governance_addr,
        chain_admin: deployed.chain_admin,
    };
    accept_ownership(ctx, &accept_input).await?;

    Ok(output)
}

// ── Output structs ──────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct HubInitInputEcho {
    pub sender: Address,
    pub owner: Address,
    pub l1_rpc_url: String,
    pub era_chain_id: u64,
    pub with_legacy_bridge: bool,
    pub simulate: bool,
}

#[derive(Serialize)]
pub struct HubInitOutputData {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
    pub core_ecosystem_contracts: HubCoreEcosystemContracts,
    pub bridges: HubBridges,
    pub l1: HubL1Contracts,
}

#[derive(Serialize)]
pub struct HubCoreEcosystemContracts {
    pub bridgehub_proxy_addr: Address,
    pub message_root_proxy_addr: Address,
    pub transparent_proxy_admin_addr: Address,
    pub stm_deployment_tracker_proxy_addr: Address,
    pub native_token_vault_addr: Address,
    pub chain_asset_handler_proxy_addr: Address,
}

#[derive(Serialize)]
pub struct HubBridgeEntry {
    pub l1_address: Address,
}

#[derive(Serialize)]
pub struct HubBridges {
    pub erc20: HubBridgeEntry,
    pub shared: HubBridgeEntry,
    pub l1_nullifier_addr: Address,
}

#[derive(Serialize)]
pub struct HubL1Contracts {
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
}

impl HubInitOutputData {
    pub fn from_deploy_output(output: &DeployL1CoreContractsOutput) -> Self {
        let deployed = &output.deployed_addresses;
        Self {
            create2_factory_addr: output.contracts.create2_factory_addr,
            create2_factory_salt: output.contracts.create2_factory_salt,
            core_ecosystem_contracts: HubCoreEcosystemContracts {
                bridgehub_proxy_addr: deployed.bridgehub.bridgehub_proxy_addr,
                message_root_proxy_addr: deployed.bridgehub.message_root_proxy_addr,
                transparent_proxy_admin_addr: deployed.transparent_proxy_admin_addr,
                stm_deployment_tracker_proxy_addr: deployed
                    .bridgehub
                    .ctm_deployment_tracker_proxy_addr,
                native_token_vault_addr: deployed.native_token_vault_addr,
                chain_asset_handler_proxy_addr: deployed
                    .bridgehub
                    .chain_asset_handler_proxy_addr,
            },
            bridges: HubBridges {
                erc20: HubBridgeEntry {
                    l1_address: deployed.bridges.erc20_bridge_proxy_addr,
                },
                shared: HubBridgeEntry {
                    l1_address: deployed.bridges.shared_bridge_proxy_addr,
                },
                l1_nullifier_addr: deployed.bridges.l1_nullifier_proxy_addr,
            },
            l1: HubL1Contracts {
                governance_addr: deployed.governance_addr,
                chain_admin_addr: deployed.chain_admin,
                access_control_restriction_addr: deployed.access_control_restriction_addr,
            },
        }
    }
}
