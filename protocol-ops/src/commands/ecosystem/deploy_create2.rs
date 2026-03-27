use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{
    constants::DETERMINISTIC_CREATE2_ADDRESS,
    forge::{Forge, ForgeRunner},
    logger,
    wallets::Wallet,
};

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct DeployCreate2Args {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: DeployCreate2Args) -> anyhow::Result<()> {
    let deployer = Wallet::parse(args.shared.private_key, args.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    logger::step("Deploying CREATE2 factory...");
    deploy_create2_factory(&mut runner, &deployer)?;

    write_output_if_requested(
        "ecosystem.deploy-create2",
        args.shared.out_path.as_deref(),
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({}),
    )?;

    logger::info(format!(
        "CREATE2 factory at: {}",
        DETERMINISTIC_CREATE2_ADDRESS
    ));

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
