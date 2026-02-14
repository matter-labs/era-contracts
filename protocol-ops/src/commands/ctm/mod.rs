use clap::Subcommand;
use xshell::Shell;

use crate::commands::ctm::{
    accept_ownership::CtmAcceptOwnershipArgs,
    deploy::CtmDeployArgs,
    init::CtmInitArgs,
    upgrade::CtmUpgradeArgs,
};

pub(crate) mod accept_ownership;
pub(crate) mod deploy;
pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum CtmCommands {
    /// Deploy CTM contracts
    Deploy(CtmDeployArgs),
    /// Accept ownership of CTM contracts
    AcceptOwnership(CtmAcceptOwnershipArgs),
    /// Initialize CTM (deploy + accept ownership + register)
    Init(CtmInitArgs),
    /// Upgrade ctm to new protocol version
    Upgrade(CtmUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: CtmCommands) -> anyhow::Result<()> {
    match args {
        CtmCommands::Deploy(args) => deploy::run(args, shell).await,
        CtmCommands::AcceptOwnership(args) => accept_ownership::run(args, shell).await,
        CtmCommands::Init(args) => init::run(args, shell).await,
        CtmCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
