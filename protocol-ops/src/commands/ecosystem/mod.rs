use clap::Subcommand;

use crate::{
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::sync_runtime_contracts::SyncRuntimeContractsArgs,
    commands::ecosystem::upgrade::{UpgradeGovernanceArgs, UpgradePrepareArgs},
};

pub(crate) mod init;
pub(crate) mod sync_runtime_contracts;
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
    /// Sync addresses redeployed by `upgrade-prepare` into a zkstack
    /// workspace's runtime contracts.yaml files. Replaces downstream
    /// `update-permanent-values.sh`-style sed glue.
    #[command(name = "sync-runtime-contracts")]
    SyncRuntimeContracts(SyncRuntimeContractsArgs),
}

pub(crate) async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::UpgradePrepare(args) => upgrade::run_upgrade_prepare(args).await,
        EcosystemCommands::UpgradeGovernance(args) => upgrade::run_upgrade_governance(args).await,
        EcosystemCommands::SyncRuntimeContracts(args) => sync_runtime_contracts::run(args).await,
    }
}
