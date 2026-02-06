use clap::Parser;
use ethers::{contract::BaseContract, types::{Address, H256}};
use lazy_static::lazy_static;
use protocol_ops_common::{
    forge::{Forge, ForgeArgs, ForgeRunner},
    logger,
};
use protocol_ops_config::{
    forge_interface::script_params::REGISTER_CTM_SCRIPT_PARAMS,
    traits::ReadConfig,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::abi::IREGISTERCTMABI_ABI;
use crate::admin_functions::AdminScriptOutputInner;
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext, SenderAuth};
use crate::utils::paths;

lazy_static! {
    static ref REGISTER_CTM_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERCTMABI_ABI.clone());
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubRegisterCtmArgs {
    /// Bridgehub proxy address
    #[clap(long)]
    pub bridgehub: Address,

    /// CTM (State Transition Manager) proxy address to register
    #[clap(long)]
    pub ctm_proxy: Address,

    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, visible_alias = "pk", help = "Sender private key")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Sender address")]
    pub sender: Option<Address>,
    #[clap(long, help = "Simulate against anvil fork (no on-chain changes)")]
    pub simulate: bool,
    #[clap(long, help = "Use dev defaults")]
    pub dev: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

/// Input parameters for registering a CTM on the bridgehub.
#[derive(Debug, Clone)]
pub struct RegisterCtmInput {
    pub bridgehub: Address,
    pub ctm_proxy: Address,
}

/// Output from registering a CTM.
#[derive(Debug, Clone)]
pub struct RegisterCtmOutput {
    pub admin_script_output: AdminScriptOutputInner,
}

/// Register a CTM on the bridgehub.
pub fn register_ctm(ctx: &mut ForgeContext, input: &RegisterCtmInput) -> anyhow::Result<RegisterCtmOutput> {
    // Encode calldata for registerCTM
    // The third parameter (broadcast) is always true when we're running via ForgeContext
    let calldata = REGISTER_CTM_FUNCTIONS
        .encode("registerCTM", (input.bridgehub, input.ctm_proxy, true))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    // Build forge command
    let mut forge = Forge::new(ctx.foundry_scripts_path)
        .script(&REGISTER_CTM_SCRIPT_PARAMS.script(), ctx.forge_args.clone())
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

    logger::info("Registering CTM on Bridgehub...");
    ctx.runner.run(ctx.shell, forge)?;

    // Read output
    let output_path = REGISTER_CTM_SCRIPT_PARAMS.output(ctx.foundry_scripts_path);
    let admin_script_output = AdminScriptOutputInner::read(ctx.shell, output_path)?;

    Ok(RegisterCtmOutput { admin_script_output })
}

pub async fn run(args: HubRegisterCtmArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.dev, args.simulate, &args.l1_rpc_url)?;

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    if is_simulation {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
    }

    logger::info(format!("Registering CTM as sender: {:#x}", sender));
    logger::info(format!("Bridgehub: {:#x}", args.bridgehub));
    logger::info(format!("CTM proxy: {:#x}", args.ctm_proxy));

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

    let input = RegisterCtmInput {
        bridgehub: args.bridgehub,
        ctm_proxy: args.ctm_proxy,
    };

    let output = register_ctm(&mut ctx, &input)?;

    let plan = build_plan(&input, &output, ctx.runner);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    if is_simulation {
        logger::outro("CTM registration simulation complete (no on-chain changes)");
    } else {
        logger::outro("CTM registered on Bridgehub");
    }

    drop(execution_mode);

    Ok(())
}

fn build_plan(input: &RegisterCtmInput, _output: &RegisterCtmOutput, runner: &ForgeRunner) -> serde_json::Value {
    let mut transactions = Vec::new();
    for run in runner.runs() {
        if let Some(txs) = run.transactions() {
            for tx in txs {
                transactions.push(tx.clone());
            }
        }
    }

    json!({
        "command": "hub.register-ctm",
        "config": {
            "bridgehub": format!("{:#x}", input.bridgehub),
            "ctm_proxy": format!("{:#x}", input.ctm_proxy),
        },
        "transactions": transactions,
    })
}
