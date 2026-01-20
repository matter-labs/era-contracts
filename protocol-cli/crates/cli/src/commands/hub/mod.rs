use clap::Subcommand;
use xshell::Shell;

use crate::{
    commands::hub::{
        deploy::HubDeployArgs,
        init::HubInitArgs,
        register_chain::HubRegisterChainArgs,
        upgrade::HubUpgradeArgs,
    }
};

pub(crate) mod init;
pub(crate) mod deploy;
pub(crate) mod register_chain;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum HubCommands {
    /// Initialize CTM
    Init(HubInitArgs),
    /// Upgrade hub to new protocol version
    Upgrade(HubUpgradeArgs),
    /// Deploy core ecosystem contracts (Bridgehub, etc.)
    Deploy(HubDeployArgs),
    /// Register a new chain with the hub
    RegisterChain(HubRegisterChainArgs),
}

pub(crate) async fn run(shell: &Shell, args: HubCommands) -> anyhow::Result<()> {
    match args {
        HubCommands::Init(args) => init::run(args, shell).await,
        HubCommands::Deploy(args) => deploy::run(args, shell).await,
        HubCommands::RegisterChain(args) => register_chain::run(args, shell).await,
        HubCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
