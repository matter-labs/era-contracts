use clap::Parser;
use ethers::types::{Address, H256};
use crate::common::{
    forge::{ForgeArgs, ForgeRunner},
    logger,
};
use crate::config::{
    forge_interface::{
        deploy_chain_admin::{input::DeployChainAdminConfig, output::DeployChainAdminOutput},
        script_params::DEPLOY_CHAIN_ADMIN_SCRIPT_PARAMS,
    },
    traits::{ReadConfig, SaveConfig},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext, SenderAuth};
use crate::utils::paths;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainDeployAdminArgs {
    /// Owner address for the ChainAdmin contract (default: sender)
    #[clap(long)]
    pub owner: Option<Address>,

    /// Token multiplier setter address (default: zero address)
    #[clap(long)]
    pub token_multiplier_setter: Option<Address>,

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
}

/// Input parameters for deploying a ChainAdmin contract.
#[derive(Debug, Clone)]
pub struct DeployAdminInput {
    pub owner: Address,
    pub token_multiplier_setter: Option<Address>,
}

/// Deploy a ChainAdmin contract and return the output.
pub fn deploy_admin(ctx: &mut ForgeContext, input: &DeployAdminInput) -> anyhow::Result<DeployChainAdminOutput> {
    let deploy_config = DeployChainAdminConfig::new(input.owner, input.token_multiplier_setter);

    // Write input config
    let input_path = DEPLOY_CHAIN_ADMIN_SCRIPT_PARAMS.input(ctx.foundry_scripts_path);
    deploy_config.save(ctx.shell, input_path)?;

    logger::info("Deploying ChainAdmin contract...");
    ctx.run(&DEPLOY_CHAIN_ADMIN_SCRIPT_PARAMS, &deploy_config)
}

pub async fn run(args: ChainDeployAdminArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

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

    logger::info(format!("Deploying ChainAdmin as sender: {:#x}", sender));
    logger::info(format!("Owner will be: {:#x}", owner));

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

    let input = DeployAdminInput {
        owner,
        token_multiplier_setter: args.token_multiplier_setter,
    };

    let output = deploy_admin(&mut ctx, &input)?;

    let result = build_output(&output, ctx.runner);
    let result_json = serde_json::to_string_pretty(&result)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &result_json)?;
        logger::info(format!("Output written to: {}", out_path.display()));
    } else {
        println!("{}", result_json);
    }

    if is_simulation {
        logger::outro("ChainAdmin deploy simulation complete (no on-chain changes)");
    } else {
        logger::outro("ChainAdmin deployed");
    }

    drop(execution_mode);

    Ok(())
}

fn build_output(output: &DeployChainAdminOutput, runner: &ForgeRunner) -> serde_json::Value {
    let runs: Vec<_> = runner.runs().iter().map(|r| json!({
        "script": r.script.display().to_string(),
        "run": r.payload,
    })).collect();

    json!({
        "command": "chain.deploy-admin",
        "runs": runs,
        "output": {
            "chain_admin_addr": format!("{:#x}", output.chain_admin_addr),
        },
    })
}
