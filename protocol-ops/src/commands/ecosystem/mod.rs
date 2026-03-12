use clap::Subcommand;
use xshell::Shell;

use crate::{
    commands::ecosystem::deploy_create2::DeployCreate2Args,
    commands::ecosystem::deploy_erc20::DeployErc20Args,
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::upgrade::EcosystemUpgradeArgs,
};

pub(crate) mod deploy_create2;
pub(crate) mod deploy_erc20;
pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Deploy the deterministic CREATE2 factory (only needed for dev networks)
    DeployCreate2(DeployCreate2Args),
    /// Deploy testnet ERC20 tokens (DAI, WBTC, etc.)
    DeployErc20(DeployErc20Args),
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Upgrade ecosystem to new protocol version
    Upgrade(EcosystemUpgradeArgs),
}

pub(crate) async fn run(shell: &Shell, args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::DeployCreate2(args) => deploy_create2::run(args, shell).await,
        EcosystemCommands::DeployErc20(args) => deploy_erc20::run(args, shell).await,
        EcosystemCommands::Init(args) => init::run(args, shell).await,
        EcosystemCommands::Upgrade(args) => upgrade::run(args, shell).await,
    }
}
