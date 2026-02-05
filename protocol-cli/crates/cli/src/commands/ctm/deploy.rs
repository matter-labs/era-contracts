use clap::Parser;
use ethers::{contract::BaseContract, types::{Address, H256}};
use lazy_static::lazy_static;
use protocol_cli_common::{
    forge::{Forge, ForgeArgs, ForgeRunner},
    logger,
};
use protocol_cli_config::{
    forge_interface::{
        deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
        deploy_ecosystem::input::InitialDeploymentConfig,
        script_params::DEPLOY_CTM_SCRIPT_PARAMS,
    },
    traits::{ReadConfig, SaveConfig},
};
use protocol_cli_types::{L1Network, VMOption};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::abi::IDEPLOYCTMABI_ABI;
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext, SenderAuth};
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

/// Input parameters for deploying CTM contracts.
#[derive(Debug, Clone)]
pub struct CtmDeployInput {
    pub bridgehub: Address,
    pub owner: Address,
    pub vm_type: VMOption,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
}

/// Deploy CTM contracts and return the output.
pub fn deploy(ctx: &mut ForgeContext, input: &CtmDeployInput) -> anyhow::Result<DeployCTMOutput> {
    let l1_network = L1Network::Localhost;
    let initial_deployment_config = InitialDeploymentConfig::default();

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
        resolve_execution(args.private_key, args.sender, args.dev, args.simulate, &args.l1_rpc_url)?;
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

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
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
    };

    let output = deploy(&mut ctx, &input)?;

    let plan = build_plan(&output, ctx.runner, &input);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    if is_simulation {
        logger::outro("CTM deploy simulation complete (no on-chain changes)");
    } else {
        logger::outro("CTM contracts deployed");
    }

    drop(execution_mode);

    Ok(())
}

fn build_plan(output: &DeployCTMOutput, runner: &ForgeRunner, input: &CtmDeployInput) -> serde_json::Value {
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
        "command": "ctm.deploy",
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
