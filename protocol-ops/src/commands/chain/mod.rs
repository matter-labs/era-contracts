use clap::Subcommand;

use crate::commands::chain::{
    gateway::GatewayCommands, init::ChainInitArgs,
    set_upgrade_timestamp::ChainSetUpgradeTimestampArgs, upgrade::ChainUpgradeArgs,
};

pub(crate) mod admin_call_builder;
pub(crate) mod gateway;
pub(crate) mod init;
pub(crate) mod set_upgrade_timestamp;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ChainCommands {
    /// Initialize new chain
    Init(ChainInitArgs),
    /// Upgrade chain to new protocol version
    Upgrade(ChainUpgradeArgs),
    /// Set upgrade timestamp so server can detect pending upgrade
    SetUpgradeTimestamp(ChainSetUpgradeTimestampArgs),
    /// Gateway operations: converting a chain into a gateway or migrating to one
    #[command(subcommand)]
    Gateway(GatewayCommands),
}

pub(crate) async fn run(args: ChainCommands) -> anyhow::Result<()> {
    match args {
        ChainCommands::Init(args) => init::run(args).await,
        ChainCommands::Upgrade(args) => upgrade::run(args).await,
        ChainCommands::SetUpgradeTimestamp(args) => set_upgrade_timestamp::run(args).await,
        ChainCommands::Gateway(cmd) => gateway::run(cmd).await,
    }
}
