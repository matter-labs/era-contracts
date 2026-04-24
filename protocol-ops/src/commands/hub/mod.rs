use clap::Subcommand;

use crate::commands::hub::init::HubInitArgs;

pub(crate) mod accept_ownership;
pub(crate) mod deploy;
pub(crate) mod init;
pub(crate) mod register_ctm;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum HubCommands {
    /// Initialize hub (deploy + accept ownership)
    Init(HubInitArgs),
}

pub(crate) async fn run(args: HubCommands) -> anyhow::Result<()> {
    match args {
        HubCommands::Init(args) => init::run(args).await,
    }
}
