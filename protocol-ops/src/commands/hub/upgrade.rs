use clap::Parser;
use crate::common::forge::{ForgeArgs, ForgeRunner};
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: HubUpgradeArgs, shell: &Shell) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new();
    Ok(())
}
