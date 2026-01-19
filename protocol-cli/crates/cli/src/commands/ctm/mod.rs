use clap::Subcommand;
use xshell::Shell;

use crate::{commands::ctm::init::CtmInitArgs, commands::ctm::upgrade::CtmUpgradeArgs};

pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum CtmCommands {
    /// Initialize CTM
    Init(CtmInitArgs),
    /// Upgrade ctm to new protocol version
    Upgrade(CtmUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: CtmCommands) -> anyhow::Result<()> {
    match args {
        CtmCommands::Init(args) => init::run(args, shell).await,
        CtmCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
