use clap::Subcommand;

use crate::commands::ctm::init::CtmInitArgs;

pub(crate) mod accept_ownership;
pub(crate) mod deploy;
pub(crate) mod init;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum CtmCommands {
    /// Initialize CTM (Chain Type Manager)
    Init(CtmInitArgs),
}

pub(crate) async fn run(args: CtmCommands) -> anyhow::Result<()> {
    match args {
        CtmCommands::Init(args) => init::run(args).await,
    }
}
