use clap::Subcommand;

use crate::{
    commands::ecosystem::deploy_create2::DeployCreate2Args,
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::upgrade::EcosystemUpgradeArgs,
};

pub(crate) mod deploy_create2;
pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Deploy the deterministic CREATE2 factory (only needed for dev networks)
    DeployCreate2(DeployCreate2Args),
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Upgrade ecosystem to new protocol version
    Upgrade(EcosystemUpgradeArgs),
}

pub(crate) async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::DeployCreate2(args) => deploy_create2::run(args).await,
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::Upgrade(args) => upgrade::run(args).await,
    }
}
