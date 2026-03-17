use std::path::PathBuf;

use clap::Parser;
use ethers::{
    contract::BaseContract,
    types::{Address, H256},
};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::abi::IDEPLOYCTMABI_ABI;
use crate::commands::output::CommandEnvelope;
use crate::common::{
    forge::{resolve_execution, ExecutionMode, Forge, ForgeArgs, ForgeContext, ForgeRunner, SenderAuth},
    logger,
    traits::{ReadConfig, SaveConfig},
};
use crate::config::{
    forge_interface::{
        deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
        deploy_ecosystem::input::InitialDeploymentConfig,
        permanent_values::PermanentValuesConfig,
        script_params::DEPLOY_CTM_SCRIPT_PARAMS,
    },
};
use crate::types::{L1Network, VMOption};
use crate::common::paths;

lazy_static! {
    static ref DEPLOY_CTM_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYCTMABI_ABI.clone());
}

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmDeployArgs {
    // Input
    /// Bridgehub proxy address
    #[clap(long, help_heading = "Input")]
    pub bridgehub: Address,

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

    // Execution
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545", help_heading = "Execution")]
    pub l1_rpc_url: String,
    /// Simulate against anvil fork (no on-chain changes)
    #[clap(long, help_heading = "Execution")]
    pub simulate: bool,

    // Output
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

    // Advanced input
    /// VM type: zksyncos (default) or eravm
    #[clap(long, value_enum, default_value_t = VMOption::ZKSyncOsVM, help_heading = "Advanced input")]
    pub vm_type: VMOption,
    /// Reuse governance and admin contracts from hub (default: true)
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub reuse_gov_and_admin: bool,
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

pub async fn run(args: CtmDeployArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    if is_simulation {
        logger::info(format!("Simulation mode: forking {} via anvil", args.l1_rpc_url));
    }

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);
    let mut runner = ForgeRunner::new();
    let mut ctx = ForgeContext {
        shell,
        foundry_scripts_path: foundry_scripts_path.as_path(),
        runner: &mut runner,
        forge_args: &args.forge_args.script,
        l1_rpc_url: effective_rpc,
        auth: &auth,
    };

    let input = CtmDeployInput {
        bridgehub: args.bridgehub,
        owner,
        vm_type: args.vm_type,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    let output = deploy(&mut ctx, &input)?;

    let ctm_proxy_addr = output.deployed_addresses.state_transition.state_transition_proxy_addr;

    if let Some(out_path) = &args.out {
        let input_echo = CtmDeployInputEcho::from_input(&input);
        let output_data = CtmDeployOutputData::from_deploy_output(&output);
        let envelope = CommandEnvelope::new("ctm.deploy", input_echo, output_data, ctx.runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    if is_simulation {
        logger::outro(format!("CTM deploy simulation complete — CTM Proxy: {:#x}", ctm_proxy_addr));
    } else {
        logger::outro(format!("CTM Proxy deployed at: {:#x}", ctm_proxy_addr));
    }

    drop(execution_mode);
    Ok(())
}

// ── Library deploy() ────────────────────────────────────────────────────────

/// Input parameters for deploying CTM contracts.
#[derive(Debug, Clone)]
pub struct CtmDeployInput {
    pub bridgehub: Address,
    pub owner: Address,
    pub vm_type: VMOption,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}

/// Deploy CTM contracts and return the output.
pub fn deploy(ctx: &mut ForgeContext, input: &CtmDeployInput) -> anyhow::Result<DeployCTMOutput> {
    let l1_network = L1Network::Localhost;
    let mut initial_deployment_config = InitialDeploymentConfig::default();

    if let Some(addr) = input.create2_factory_addr {
        initial_deployment_config.create2_factory_addr = Some(addr);
    }
    if let Some(salt) = input.create2_factory_salt {
        initial_deployment_config.create2_factory_salt = salt;
    }

    let permanent_values = PermanentValuesConfig::new(
        initial_deployment_config.create2_factory_addr,
        initial_deployment_config.create2_factory_salt,
    );
    permanent_values.save(ctx.shell, PermanentValuesConfig::path(ctx.foundry_scripts_path))?;

    let deploy_config = DeployCTMConfig::new(
        input.owner,
        &initial_deployment_config,
        input.with_testnet_verifier,
        l1_network,
        input.with_legacy_bridge,
        input.vm_type,
    );

    let input_path = DEPLOY_CTM_SCRIPT_PARAMS.input(ctx.foundry_scripts_path);
    deploy_config.save(ctx.shell, input_path)?;

    let calldata = DEPLOY_CTM_FUNCTIONS
        .encode("runWithBridgehub", (input.bridgehub, input.reuse_gov_and_admin))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    let mut forge = Forge::new(ctx.foundry_scripts_path)
        .script(&DEPLOY_CTM_SCRIPT_PARAMS.script(), ctx.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(ctx.l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match ctx.auth {
        SenderAuth::PrivateKey(pk) => {
            forge = forge.with_private_key(*pk);
        }
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked();
        }
    }

    logger::info("Deploying CTM contracts...");
    ctx.runner.run(ctx.shell, forge)?;

    let output_path = DEPLOY_CTM_SCRIPT_PARAMS.output(ctx.foundry_scripts_path);
    DeployCTMOutput::read(ctx.shell, output_path)
}

// ── Output structs ──────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct CtmDeployInputEcho {
    pub bridgehub: Address,
    pub vm_type: VMOption,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
}

impl CtmDeployInputEcho {
    pub fn from_input(input: &CtmDeployInput) -> Self {
        Self {
            bridgehub: input.bridgehub,
            vm_type: input.vm_type,
            reuse_gov_and_admin: input.reuse_gov_and_admin,
            with_testnet_verifier: input.with_testnet_verifier,
            with_legacy_bridge: input.with_legacy_bridge,
        }
    }
}

#[derive(Serialize)]
pub struct CtmStateTransitionOutput {
    pub proxy_addr: Address,
    pub verifier_addr: Address,
    pub genesis_upgrade_addr: Address,
    pub default_upgrade_addr: Address,
    pub bytecodes_supplier_addr: Address,
}

#[derive(Serialize)]
pub struct CtmDeployOutputData {
    pub state_transition: CtmStateTransitionOutput,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub validator_timelock_addr: Address,
    pub rollup_l1_da_validator_addr: Address,
    pub no_da_validium_l1_validator_addr: Address,
    pub blobs_zksync_os_l1_da_validator_addr: Option<Address>,
    pub server_notifier_proxy_addr: Address,
    pub diamond_cut_data: String,
}

impl CtmDeployOutputData {
    pub fn from_deploy_output(output: &DeployCTMOutput) -> Self {
        let deployed = &output.deployed_addresses;
        Self {
            state_transition: CtmStateTransitionOutput {
                proxy_addr: deployed.state_transition.state_transition_proxy_addr,
                verifier_addr: deployed.state_transition.verifier_addr,
                genesis_upgrade_addr: deployed.state_transition.genesis_upgrade_addr,
                default_upgrade_addr: deployed.state_transition.default_upgrade_addr,
                bytecodes_supplier_addr: deployed.state_transition.bytecodes_supplier_addr,
            },
            governance_addr: deployed.governance_addr,
            chain_admin_addr: deployed.chain_admin,
            validator_timelock_addr: deployed.validator_timelock_addr,
            rollup_l1_da_validator_addr: deployed.rollup_l1_da_validator_addr,
            no_da_validium_l1_validator_addr: deployed.no_da_validium_l1_validator_addr,
            blobs_zksync_os_l1_da_validator_addr: deployed.blobs_zksync_os_l1_da_validator_addr,
            server_notifier_proxy_addr: deployed.server_notifier_proxy_addr,
            diamond_cut_data: output.contracts_config.diamond_cut_data.clone(),
        }
    }
}
