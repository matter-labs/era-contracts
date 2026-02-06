use clap::Parser;
use protocol_ops_common::forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs};
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: CtmUpgradeArgs, shell: &Shell) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    Ok(())
}
