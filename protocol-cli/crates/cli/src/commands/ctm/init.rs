use clap::Parser;
use protocol_cli_common::forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs};
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmInitArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: CtmInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    Ok(())
}
