use std::path::PathBuf;

use clap::Parser;
use ethers::{contract::BaseContract, types::{Address, H256}};
use lazy_static::lazy_static;
use crate::common::{
    forge::{resolve_execution, ExecutionMode, Forge, ForgeArgs, ForgeContext, ForgeRunner, SenderAuth},
    logger,
};
use crate::config::{
    forge_interface::{
        deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
        deploy_ecosystem::input::InitialDeploymentConfig,
        permanent_values::PermanentValuesConfig,
        script_params::DEPLOY_CTM_SCRIPT_PARAMS,
    },
    traits::{ReadConfig, SaveConfig},
};
use crate::types::{L1Network, VMOption};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::abi::IDEPLOYCTMABI_ABI;
use crate::utils::paths;

lazy_static! {
    static ref DEPLOY_CTM_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYCTMABI_ABI.clone());
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmDeployArgs {
    /// Bridgehub proxy address
    #[clap(long)]
    pub bridgehub: Address,

    /// Owner address for the deployed contracts (default: sender)
    #[clap(long)]
    pub owner: Option<Address>,

    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, visible_alias = "pk", help = "Sender private key")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Sender address")]
    pub sender: Option<Address>,
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
    /// VM type: zksyncos (default) or eravm
    #[clap(long, default_value = "zksyncos")]
    pub vm_type: String,
    /// Reuse governance and admin contracts from hub (default: true)
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true")]
    pub reuse_gov_and_admin: bool,
    /// Use testnet verifier (default: true)
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true")]
    pub with_testnet_verifier: bool,
    /// Enable support for legacy bridge testing (default: false)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub with_legacy_bridge: bool,

    // Output
    #[clap(long, help = "Write full JSON output to file", help_heading = "Output")]
    pub out: Option<PathBuf>,
}

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

    // Override create2 factory settings if provided
    if let Some(addr) = input.create2_factory_addr {
        initial_deployment_config.create2_factory_addr = Some(addr);
    }
    if let Some(salt) = input.create2_factory_salt {
        initial_deployment_config.create2_factory_salt = salt;
    }

    // Update permanent-values.toml so Forge scripts use the correct factory
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

    // Write input config
    let input_path = DEPLOY_CTM_SCRIPT_PARAMS.input(ctx.foundry_scripts_path);
    deploy_config.save(ctx.shell, input_path)?;

    // Encode calldata for runWithBridgehub
    let calldata = DEPLOY_CTM_FUNCTIONS
        .encode("runWithBridgehub", (input.bridgehub, input.reuse_gov_and_admin))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    // Build forge command
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

    // Read output
    let output_path = DEPLOY_CTM_SCRIPT_PARAMS.output(ctx.foundry_scripts_path);
    DeployCTMOutput::read(ctx.shell, output_path)
}

pub async fn run(args: CtmDeployArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let vm_type = match args.vm_type.to_lowercase().as_str() {
        "eravm" | "era" => VMOption::EraVM,
        "zksyncos" | "zksync" | "zksync-os" => VMOption::ZKSyncOsVM,
        _ => anyhow::bail!("Invalid VM type '{}'. Use 'zksyncos' or 'eravm'", args.vm_type),
    };

    let (auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);

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
        vm_type,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    let output = deploy(&mut ctx, &input)?;

    let ctm_proxy_addr = output.deployed_addresses.state_transition.state_transition_proxy_addr;

    if let Some(out_path) = &args.out {
        let result = build_output(&output, ctx.runner, &input);
        let result_json = serde_json::to_string_pretty(&result)?;
        std::fs::write(out_path, &result_json)?;
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

fn build_output(output: &DeployCTMOutput, runner: &ForgeRunner, input: &CtmDeployInput) -> serde_json::Value {
    let deployed = &output.deployed_addresses;

    let runs: Vec<_> = runner.runs().iter().map(|r| json!({
        "script": r.script.display().to_string(),
        "run": r.payload,
    })).collect();

    json!({
        "command": "ctm.deploy",
        "input": {
            "bridgehub": format!("{:#x}", input.bridgehub),
            "vm_type": format!("{:?}", input.vm_type),
            "reuse_gov_and_admin": input.reuse_gov_and_admin,
            "with_testnet_verifier": input.with_testnet_verifier,
            "with_legacy_bridge": input.with_legacy_bridge,
        },
        "runs": runs,
        "output": {
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
