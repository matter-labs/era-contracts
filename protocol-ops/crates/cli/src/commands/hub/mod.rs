use clap::Subcommand;
use xshell::Shell;

use crate::commands::hub::{
    accept_ownership::HubAcceptOwnershipArgs,
    deploy::HubDeployArgs,
    init::HubInitArgs,
    register_chain::HubRegisterChainArgs,
    register_ctm::HubRegisterCtmArgs,
    upgrade::HubUpgradeArgs,
};

pub(crate) mod accept_ownership;
pub(crate) mod deploy;
pub(crate) mod init;
pub(crate) mod register_chain;
pub(crate) mod register_ctm;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum HubCommands {
    /// Deploy core ecosystem contracts (Bridgehub, etc.)
    Deploy(HubDeployArgs),
    /// Accept ownership of hub contracts
    AcceptOwnership(HubAcceptOwnershipArgs),
    /// Initialize hub (deploy + accept ownership)
    Init(HubInitArgs),
    /// Register a CTM on the bridgehub
    RegisterCtm(HubRegisterCtmArgs),
    /// Register a new chain with the hub
    RegisterChain(HubRegisterChainArgs),
    /// Upgrade hub to new protocol version
    Upgrade(HubUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: HubCommands) -> anyhow::Result<()> {
    match args {
        HubCommands::Deploy(args) => deploy::run(args, shell).await,
        HubCommands::AcceptOwnership(args) => accept_ownership::run(args, shell).await,
        HubCommands::Init(args) => init::run(args, shell).await,
        HubCommands::RegisterCtm(args) => register_ctm::run(args, shell).await,
        HubCommands::RegisterChain(args) => register_chain::run(args, shell).await,
        HubCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
