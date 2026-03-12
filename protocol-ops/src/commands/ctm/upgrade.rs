use clap::Parser;
use crate::common::forge::ForgeArgs;
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(_args: CtmUpgradeArgs, _shell: &Shell) -> anyhow::Result<()> {
    // Placeholder
    Ok(())
}
