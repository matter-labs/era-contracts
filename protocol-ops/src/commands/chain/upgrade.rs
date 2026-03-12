use clap::Parser;
use crate::common::forge::ForgeArgs;
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(_args: ChainUpgradeArgs, _shell: &Shell) -> anyhow::Result<()> {
    // Placeholder
    Ok(())
}
