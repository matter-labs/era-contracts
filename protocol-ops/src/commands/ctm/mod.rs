use clap::Subcommand;

use crate::commands::ctm::init::CtmInitArgs;

pub mod deploy;
pub mod init;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum CtmCommands {
    /// Initialize CTM (Chain Type Manager)
    Init(CtmInitArgs),
}

pub async fn run(args: CtmCommands) -> anyhow::Result<()> {
    match args {
        CtmCommands::Init(args) => init::run(args).await,
    }
}
