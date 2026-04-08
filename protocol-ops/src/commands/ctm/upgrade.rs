use clap::Parser;
use crate::common::forge::ForgeScriptArgs;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
}

pub async fn run(_args: CtmUpgradeArgs) -> anyhow::Result<()> {
    // Placeholder
    Ok(())
}
