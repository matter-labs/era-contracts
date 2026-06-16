use clap::Subcommand;

use crate::commands::hub::init::HubInitArgs;

pub mod deploy;
pub mod init;
pub mod register_ctm;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum HubCommands {
    /// Initialize hub (deploy + accept ownership)
    Init(HubInitArgs),
}

pub async fn run(args: HubCommands) -> anyhow::Result<()> {
    match args {
        HubCommands::Init(args) => init::run(args).await,
    }
}
