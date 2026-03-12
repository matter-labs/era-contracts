use clap::Subcommand;
use xshell::Shell;

use crate::commands::hub::{
    init::HubInitArgs,
    upgrade::HubUpgradeArgs,
};

pub(crate) mod accept_ownership;
pub(crate) mod deploy;
pub(crate) mod init;
pub(crate) mod register_ctm;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum HubCommands {
    /// Initialize hub (deploy + accept ownership)
    Init(HubInitArgs),
    /// Upgrade hub to new protocol version
    Upgrade(HubUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: HubCommands) -> anyhow::Result<()> {
    match args {
        HubCommands::Init(args) => init::run(args, shell).await,
        HubCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
