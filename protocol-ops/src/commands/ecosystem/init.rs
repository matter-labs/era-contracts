use std::{path::PathBuf, str::FromStr};

use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::commands::ctm::init::{ctm_init, CtmInitInput, CtmInitOutput};
use crate::commands::ecosystem::deploy_create2::{deploy_create2_factory, DETERMINISTIC_CREATE2_ADDRESS};
use crate::commands::hub::init::{hub_init, HubInitInput};
use crate::commands::output::CommandEnvelope;
use crate::common::{
    forge::{
        resolve_execution, resolve_owner_auth, ExecutionMode, ForgeArgs, ForgeContext, ForgeRunner,
    },
    logger,
};
use crate::config::forge_interface::deploy_ecosystem::output::DeployL1CoreContractsOutput;
use crate::types::VMOption;
use crate::common::paths;

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct EcosystemInitArgs {
    // Signers
    /// Sender address
    #[clap(long, help_heading = "Signers")]
    pub sender: Option<Address>,
    /// Owner address for the deployed contracts (default: sender)
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
    /// VM type: zksyncos (default) or eravm
    #[clap(long, value_enum, default_value_t = VMOption::ZKSyncOsVM, help_heading = "Advanced input")]
    pub vm_type: VMOption,
    /// Use testnet verifier (default: true)
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_testnet_verifier: bool,
    /// Enable support for legacy bridge testing (default: false)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
    /// CREATE2 factory address (if already deployed)
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_addr: Option<Address>,
    /// CREATE2 factory salt (random by default)
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<H256>,

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: EcosystemInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);
    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));

    let owner_auth = resolve_owner_auth(
        owner, args.owner_private_key, sender, &sender_auth, is_simulation,
    )?;

    if is_simulation {
        logger::info(format!("Simulation mode: forking {} via anvil", args.l1_rpc_url));
    }

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);
    let mut runner = ForgeRunner::new();

    logger::info("Initializing ecosystem...");
    logger::info(format!("Sender: {:#x}", sender));
    logger::info(format!("Owner: {:#x}", owner));

    let create2_factory_addr = if args.create2_factory_addr.is_some() {
        args.create2_factory_addr.unwrap()
    } else {
        logger::step("Deploying CREATE2 factory...");
        let mut create2_ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &sender_auth,
        };
        deploy_create2_factory(&mut create2_ctx)?;
        logger::info(format!("CREATE2 factory at: {}", DETERMINISTIC_CREATE2_ADDRESS));
        Address::from_str(DETERMINISTIC_CREATE2_ADDRESS).unwrap()
    };
   
    let mut ctx = ForgeContext {
        shell,
        foundry_scripts_path: foundry_scripts_path.as_path(),
        runner: &mut runner,
        forge_args: &args.forge_args.script,
        l1_rpc_url: effective_rpc,
        auth: &owner_auth,
    };

    // Initialize Bridgehub contracts (shared within ecosystem)
    logger::step("Initializing hub...");
    let hub_input = HubInitInput {
        owner,
        era_chain_id: args.era_chain_id,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: Some(create2_factory_addr),
        create2_factory_salt: args.create2_factory_salt,
    };
    let hub_output = hub_init(&mut ctx, &hub_input).await?;

    let bridgehub = hub_output.deployed_addresses.bridgehub.bridgehub_proxy_addr;
    logger::info(format!("Hub initialized. Bridgehub: {:#x}", bridgehub));

    // Initialize CTM contracts
    logger::step("Initializing CTM...");
    let ctm_create2_addr = Some(create2_factory_addr);

    let ctm_input = CtmInitInput {
        bridgehub,
        owner,
        vm_type: args.vm_type,
        reuse_gov_and_admin: true, // Always reuse in ecosystem init
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: ctm_create2_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    let ctm_output = ctm_init(
        &mut ctx,
        &ctm_input,
        &owner_auth, // Accept ownership as owner (uses hub's governance)
        &owner_auth, // Register as owner (uses hub's chain_admin)
    )
    .await?;

    logger::info(format!(
        "CTM initialized. CTM proxy: {:#x}",
        ctm_output.ctm_proxy
    ));

    let bridgehub_addr = hub_output.deployed_addresses.bridgehub.bridgehub_proxy_addr;
    let ctm_proxy_addr = ctm_output.ctm_proxy;

    if let Some(out_path) = &args.out {
        let input_echo = EcosystemInitInputEcho {
            sender,
            owner,
            l1_rpc_url: args.l1_rpc_url.clone(),
            era_chain_id: args.era_chain_id,
            vm_type: args.vm_type,
            with_testnet_verifier: args.with_testnet_verifier,
            with_legacy_bridge: args.with_legacy_bridge,
            simulate: args.simulate,
        };
        let output_data = EcosystemInitOutputData::from_outputs(&hub_output, &ctm_output);
        let envelope = CommandEnvelope::new("ecosystem.init", input_echo, output_data, &runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    if is_simulation {
        logger::outro(format!(
            "Ecosystem init simulation complete\n  Bridgehub Proxy: {:#x}\n  CTM Proxy: {:#x}",
            bridgehub_addr, ctm_proxy_addr
        ));
    } else {
        logger::outro(format!(
            "Bridgehub Proxy deployed at: {:#x}\nCTM Proxy deployed at: {:#x}",
            bridgehub_addr, ctm_proxy_addr
        ));
    }

    drop(execution_mode);
    Ok(())
}

// ── Internal structs ────────────────────────────────────────────────────────

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

// ── Output structs ──────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct EcosystemInitInputEcho {
    pub sender: Address,
    pub owner: Address,
    pub l1_rpc_url: String,
    pub era_chain_id: u64,
    pub vm_type: VMOption,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
    pub simulate: bool,
}

#[derive(Serialize)]
pub struct EcosystemInitOutputData {
    pub hub: EcosystemHubOutput,
    pub ctm: EcosystemCtmOutput,
}

#[derive(Serialize)]
pub struct EcosystemHubOutput {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
    pub bridgehub_proxy_addr: Address,
    pub message_root_proxy_addr: Address,
    pub transparent_proxy_admin_addr: Address,
    pub stm_deployment_tracker_proxy_addr: Address,
    pub native_token_vault_addr: Address,
    pub chain_asset_handler_proxy_addr: Address,
    pub shared_bridge_proxy_addr: Address,
    pub erc20_bridge_proxy_addr: Address,
    pub l1_nullifier_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
}

#[derive(Serialize)]
pub struct EcosystemCtmOutput {
    pub state_transition_proxy_addr: Address,
    pub verifier_addr: Address,
    pub genesis_upgrade_addr: Address,
    pub default_upgrade_addr: Address,
    pub bytecodes_supplier_addr: Address,
    pub validator_timelock_addr: Address,
    pub rollup_l1_da_validator_addr: Address,
    pub no_da_validium_l1_validator_addr: Address,
    pub avail_l1_da_validator_addr: Address,
    pub l1_rollup_da_manager: Address,
    pub blobs_zksync_os_l1_da_validator_addr: Option<Address>,
    pub server_notifier_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub transparent_proxy_admin_addr: Address,
    pub multicall3_addr: Address,
    pub diamond_cut_data: String,
    pub force_deployments_data: Option<String>,
}

impl EcosystemInitOutputData {
    pub fn from_outputs(
        hub_output: &DeployL1CoreContractsOutput,
        ctm_output: &CtmInitOutput,
    ) -> Self {
        let hub = &hub_output.deployed_addresses;
        let ctm = &ctm_output.deploy_output.deployed_addresses;
        let ctm_config = &ctm_output.deploy_output.contracts_config;

        Self {
            hub: EcosystemHubOutput {
                create2_factory_addr: hub_output.contracts.create2_factory_addr,
                create2_factory_salt: hub_output.contracts.create2_factory_salt,
                bridgehub_proxy_addr: hub.bridgehub.bridgehub_proxy_addr,
                message_root_proxy_addr: hub.bridgehub.message_root_proxy_addr,
                transparent_proxy_admin_addr: hub.transparent_proxy_admin_addr,
                stm_deployment_tracker_proxy_addr: hub.bridgehub.ctm_deployment_tracker_proxy_addr,
                native_token_vault_addr: hub.native_token_vault_addr,
                chain_asset_handler_proxy_addr: hub.bridgehub.chain_asset_handler_proxy_addr,
                shared_bridge_proxy_addr: hub.bridges.shared_bridge_proxy_addr,
                erc20_bridge_proxy_addr: hub.bridges.erc20_bridge_proxy_addr,
                l1_nullifier_proxy_addr: hub.bridges.l1_nullifier_proxy_addr,
                governance_addr: hub.governance_addr,
                chain_admin_addr: hub.chain_admin,
                access_control_restriction_addr: hub.access_control_restriction_addr,
            },
            ctm: EcosystemCtmOutput {
                state_transition_proxy_addr: ctm.state_transition.state_transition_proxy_addr,
                verifier_addr: ctm.state_transition.verifier_addr,
                genesis_upgrade_addr: ctm.state_transition.genesis_upgrade_addr,
                default_upgrade_addr: ctm.state_transition.default_upgrade_addr,
                bytecodes_supplier_addr: ctm.state_transition.bytecodes_supplier_addr,
                validator_timelock_addr: ctm.validator_timelock_addr,
                rollup_l1_da_validator_addr: ctm.rollup_l1_da_validator_addr,
                no_da_validium_l1_validator_addr: ctm.no_da_validium_l1_validator_addr,
                avail_l1_da_validator_addr: ctm.avail_l1_da_validator_addr,
                l1_rollup_da_manager: ctm.l1_rollup_da_manager,
                blobs_zksync_os_l1_da_validator_addr: ctm.blobs_zksync_os_l1_da_validator_addr,
                server_notifier_proxy_addr: ctm.server_notifier_proxy_addr,
                governance_addr: ctm.governance_addr,
                chain_admin_addr: ctm.chain_admin,
                transparent_proxy_admin_addr: ctm.transparent_proxy_admin_addr,
                multicall3_addr: ctm_output.deploy_output.multicall3_addr,
                diamond_cut_data: ctm_config.diamond_cut_data.clone(),
                force_deployments_data: ctm_config.force_deployments_data.clone(),
            },
        }
    }
}
