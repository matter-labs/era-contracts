use clap::Subcommand;
use xshell::Shell;

use crate::{commands::hub::deploy_contracts::HubDeployContractsArgs, commands::hub::init::HubInitArgs, commands::hub::upgrade::HubUpgradeArgs};

pub(crate) mod init;
pub(crate) mod deploy_contracts;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum HubCommands {
    /// Initialize CTM
    Init(HubInitArgs),
    /// Deploy hub contracts
    DeployContracts(HubDeployContractsArgs),
    /// Upgrade hub to new protocol version
    Upgrade(HubUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: HubCommands) -> anyhow::Result<()> {
    match args {
        HubCommands::Init(args) => init::run(args, shell).await,
        HubCommands::DeployContracts(args) => deploy_contracts::run(args, shell).await,
        HubCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
