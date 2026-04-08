use std::path::PathBuf;
use clap::Parser;
use ethers::types::{Address, H256};
use crate::common::{
    constants::DETERMINISTIC_CREATE2_ADDRESS,
    forge::{Forge, ForgeRunner, ForgeScriptArgs},
    logger,
    wallets::Wallet,
};
use crate::commands::output::CommandEnvelope;
use serde_json::json;
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
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
}

pub async fn run(args: DeployCreate2Args) -> anyhow::Result<()> {
    let deployer = Wallet::parse(args.private_key, args.sender)?;
    let mut runner = ForgeRunner::new(args.simulate, &args.l1_rpc_url, args.forge_args.clone())?;

    deploy_create2_factory(&mut runner, &deployer)?;

    if let Some(out_path) = &args.out {
        let envelope = CommandEnvelope::new("ecosystem.deploy-create2", json!({}), json!({}), &runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    logger::outro(format!("CREATE2 factory at: {}", DETERMINISTIC_CREATE2_ADDRESS));

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
