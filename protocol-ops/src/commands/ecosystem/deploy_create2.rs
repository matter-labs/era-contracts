use crate::common::{
    forge::{resolve_execution, ExecutionMode, Forge, ForgeArgs, ForgeRunner, SenderAuth},
    logger,
};
use crate::utils::paths;
use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use xshell::Shell;

/// The deterministic CREATE2 factory address (Arachnid's deterministic-deployment-proxy)
pub const DETERMINISTIC_CREATE2_ADDRESS: &str = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct DeployCreate2Args {
    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, visible_alias = "pk", help = "Deployer private key")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Deployer address (for simulation)")]
    pub sender: Option<Address>,
    #[clap(long, help = "Simulate against anvil fork (no on-chain changes)")]
    pub simulate: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: DeployCreate2Args, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (auth, sender, execution_mode) = resolve_execution(
        args.private_key,
        args.sender,
        args.simulate,
        &args.l1_rpc_url,
    )?;

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    if is_simulation {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
    }

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);
    let mut runner = ForgeRunner::new();

    logger::info(format!("Deploying CREATE2 factory as: {:#x}", sender));
    logger::info(format!("Target address: {}", DETERMINISTIC_CREATE2_ADDRESS));

    // Build forge command - no input file needed
    let mut forge = Forge::new(&foundry_scripts_path)
        .script(
            &std::path::PathBuf::from("deploy-scripts/ecosystem/DeployCreate2Factory.s.sol"),
            args.forge_args.script.clone(),
        )
        .with_ffi()
        .with_rpc_url(effective_rpc.to_string())
        .with_broadcast();

    match &auth {
        SenderAuth::PrivateKey(pk) => {
            forge = forge.with_private_key(*pk);
        }
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked();
        }
    }

    runner.run(shell, forge)?;

    if is_simulation {
        logger::outro("CREATE2 factory deployment simulation complete");
    } else {
        logger::outro(format!(
            "CREATE2 factory deployed at {}",
            DETERMINISTIC_CREATE2_ADDRESS
        ));
    }

    drop(execution_mode);

    Ok(())
}
