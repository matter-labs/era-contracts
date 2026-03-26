use clap::Parser;
use ethers::types::{Address, H256};
use crate::common::{
    constants::DETERMINISTIC_CREATE2_ADDRESS,
    forge::{Forge, ForgeRunner, ForgeScriptArgs},
    logger,
    wallets::Wallet,
};
use crate::commands::output::{write_output_if_requested, OutputArgs};
use serde::{Deserialize, Serialize};

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
    #[clap(flatten)]
    #[serde(flatten)]
    pub output_args: OutputArgs,

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
}

pub async fn run(args: DeployCreate2Args) -> anyhow::Result<()> {
    let deployer = Wallet::parse(args.private_key, args.sender)?;
    let mut runner = ForgeRunner::new(args.simulate, &args.l1_rpc_url, args.forge_args.clone())?;

    logger::step("Deploying CREATE2 factory...");
    deploy_create2_factory(&mut runner, &deployer)?;

    write_output_if_requested(&args.output_args, &runner, &serde_json::json!({}), &serde_json::json!({}))?;

    logger::info(format!("CREATE2 factory at: {}", DETERMINISTIC_CREATE2_ADDRESS));

    Ok(())
}

pub fn deploy_create2_factory(runner: &mut ForgeRunner, auth: &Wallet) -> anyhow::Result<()> {
    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(
            &std::path::PathBuf::from("deploy-scripts/ecosystem/DeployCreate2Factory.s.sol"),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_wallet(auth, runner.simulate);

    runner.run(forge)
}
