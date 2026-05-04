use clap::Subcommand;

use crate::{
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::upgrade::{UpgradeGovernanceArgs, UpgradePrepareAllArgs},
};

pub(crate) mod init;
pub(crate) mod upgrade;
pub(crate) mod v31_upgrade_full;
pub(crate) mod v31_upgrade_inner;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Split-flow prepare: runs `CoreUpgrade_v31.noGovernancePrepare` once
    /// and `CTMUpgrade_v31.noGovernancePrepare` once per `--ctm-proxy`, all
    /// on a single anvil fork. Emits one combined deployer Safe bundle and
    /// per-step governance TOMLs for the downstream `upgrade-governance`.
    #[command(name = "upgrade-prepare-all")]
    UpgradePrepareAll(UpgradePrepareAllArgs),
    /// Phase 2 of the ecosystem upgrade: runs governance stages 0+1+2 on a
    /// single anvil fork (governance owner signs). Emits one Safe bundle
    /// containing all three governance calls. Pass `--governance-toml`
    /// multiple times to merge stage calls from several prepare TOMLs (one
    /// from `upgrade-prepare-all`'s core output, plus one per CTM TOML).
    #[command(name = "upgrade-governance")]
    UpgradeGovernance(UpgradeGovernanceArgs),
}

pub(crate) async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::UpgradePrepareAll(args) => upgrade::run_upgrade_prepare_all(args).await,
        EcosystemCommands::UpgradeGovernance(args) => upgrade::run_upgrade_governance(args).await,
    }
}
