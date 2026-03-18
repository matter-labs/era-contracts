use clap::Subcommand;

use crate::commands::chain::{
    init::ChainInitArgs,
    upgrade::ChainUpgradeArgs,
};

pub(crate) mod admin_call_builder;
pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ChainCommands {
    /// Initialize new chain
    Init(ChainInitArgs),
    /// Upgrade chain to new protocol version
    Upgrade(ChainUpgradeArgs),
}

pub(crate) async fn run(args: ChainCommands) -> anyhow::Result<()> {
    match args {
        ChainCommands::Init(args) => init::run(args).await,
        ChainCommands::Upgrade(args) => upgrade::run(args).await,
    }
}
