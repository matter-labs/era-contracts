use clap::Parser;
use protocol_cli_common::forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs};
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubInitArgs {
    #[clap(long, help = "Address of the hub owner")]
    pub owner: Option<String>,
    #[clap(long, help = "Address of the deployer")]
    pub deployer: Option<String>,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: HubInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    Ok(())
}
