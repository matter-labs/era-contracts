use clap::Subcommand;
use xshell::Shell;

use crate::{
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::upgrade::EcosystemUpgradeArgs,
};

pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Upgrade ecosystem to new protocol version
    Upgrade(EcosystemUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args, shell).await,
        EcosystemCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
