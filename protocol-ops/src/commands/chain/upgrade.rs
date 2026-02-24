use clap::Parser;
use crate::common::forge::{ForgeArgs, ForgeRunner};
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: ChainUpgradeArgs, shell: &Shell) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new();
    Ok(())
}
