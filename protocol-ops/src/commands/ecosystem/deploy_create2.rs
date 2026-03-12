use std::path::PathBuf;
use clap::Parser;
use ethers::types::{Address, H256};
use crate::common::{
    forge::{resolve_execution, ExecutionMode, Forge, ForgeArgs, ForgeContext, ForgeRunner, SenderAuth},
    logger, paths
};
use crate::commands::output::CommandEnvelope;
use serde_json::json;
use serde::{Deserialize, Serialize};
use xshell::Shell;

/// The deterministic CREATE2 factory address (Arachnid's deterministic-deployment-proxy)
pub const DETERMINISTIC_CREATE2_ADDRESS: &str = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct DeployCreate2Args {
    // Execution
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545", help_heading = "Execution")]
    pub l1_rpc_url: String,
    /// Simulate against anvil fork
    #[clap(long, help_heading = "Execution")]
    pub simulate: bool,
    /// Sender address
    #[clap(long, help_heading = "Execution")]
    pub sender: Option<Address>,
    /// Sender private key
    #[clap(long, visible_alias = "pk", help_heading = "Execution")]
    pub private_key: Option<H256>,

    // Output
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: DeployCreate2Args, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    if is_simulation {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
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

    deploy_create2_factory(&mut ctx)?;

    if let Some(out_path) = &args.out {
        let envelope = CommandEnvelope::new("ecosystem.deploy-create2", json!({}), json!({}), &ctx.runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }
    
    drop(execution_mode);
    Ok(())
}

pub fn deploy_create2_factory(ctx: &mut ForgeContext) -> anyhow::Result<()> {
    let mut forge = Forge::new(ctx.foundry_scripts_path)
        .script(
            &std::path::PathBuf::from("deploy-scripts/ecosystem/DeployCreate2Factory.s.sol"),
            ctx.forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(ctx.l1_rpc_url.to_string())
        .with_broadcast();

    match ctx.auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    ctx.runner.run(ctx.shell, forge)
}
