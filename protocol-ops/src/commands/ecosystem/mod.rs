use clap::Subcommand;

use crate::{
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::upgrade::{UpgradeGovernanceArgs, UpgradePrepareArgs},
};

pub(crate) mod init;
pub(crate) mod upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Phase 1 of the ecosystem upgrade: deploy new contracts (deployer EOA
    /// signs). Emits the governance calls TOML consumed by phase 2.
    #[command(name = "upgrade-prepare")]
    UpgradePrepare(UpgradePrepareArgs),
    /// Phase 2 of the ecosystem upgrade: runs governance stages 0+1+2 on a
    /// single anvil fork (governance owner signs). Emits one Safe bundle
    /// containing all three governance calls.
    #[command(name = "upgrade-governance")]
    UpgradeGovernance(UpgradeGovernanceArgs),
}

pub(crate) async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::UpgradePrepare(args) => upgrade::run_upgrade_prepare(args).await,
        EcosystemCommands::UpgradeGovernance(args) => upgrade::run_upgrade_governance(args).await,
    }
}
