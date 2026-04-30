use clap::Subcommand;

use crate::{
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::upgrade::{UpgradeGovernanceArgs, UpgradePrepareArgs},
    commands::ecosystem::upgrade_split::{
        CoreUpgradePrepareArgs, CtmUpgradePrepareArgs, UpgradePrepareAllArgs,
    },
};

pub(crate) mod init;
pub(crate) mod upgrade;
pub(crate) mod upgrade_split;
pub(crate) mod v31_upgrade_full;
pub(crate) mod v31_upgrade_inner;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Phase 1 of the ecosystem upgrade: deploy new contracts (deployer EOA
    /// signs). Emits the governance calls TOML consumed by phase 2.
    #[command(name = "upgrade-prepare")]
    UpgradePrepare(UpgradePrepareArgs),
    /// Phase 1a (split flow): deploy ecosystem-wide core contracts only.
    /// Pair with one or more `ctm-upgrade-prepare` invocations to upgrade
    /// ecosystems that host multiple CTMs.
    #[command(name = "core-upgrade-prepare")]
    CoreUpgradePrepare(CoreUpgradePrepareArgs),
    /// Phase 1b (split flow): deploy CTM-specific contracts for one CTM proxy.
    /// Run once per CTM (e.g. ZKsyncOS, EraVM) on the same anvil fork as the
    /// preceding `core-upgrade-prepare`, and run all of them before invoking
    /// `upgrade-governance`.
    #[command(name = "ctm-upgrade-prepare")]
    CtmUpgradePrepare(CtmUpgradePrepareArgs),
    /// One-shot orchestrator: runs `core-upgrade-prepare` followed by one
    /// `ctm-upgrade-prepare` per `--ctm-proxy` against a single anvil fork.
    /// Emits one combined deployer Safe bundle plus per-step governance
    /// TOMLs for the downstream `upgrade-governance` step.
    #[command(name = "upgrade-prepare-all")]
    UpgradePrepareAll(UpgradePrepareAllArgs),
    /// Phase 2 of the ecosystem upgrade: runs governance stages 0+1+2 on a
    /// single anvil fork (governance owner signs). Emits one Safe bundle
    /// containing all three governance calls. Pass `--governance-toml`
    /// multiple times to merge stage calls from several prepare TOMLs (one
    /// from `core-upgrade-prepare`, one from each `ctm-upgrade-prepare`).
    #[command(name = "upgrade-governance")]
    UpgradeGovernance(UpgradeGovernanceArgs),
}

pub(crate) async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::UpgradePrepare(args) => upgrade::run_upgrade_prepare(args).await,
        EcosystemCommands::CoreUpgradePrepare(args) => {
            upgrade_split::run_core_upgrade_prepare(args).await
        }
        EcosystemCommands::CtmUpgradePrepare(args) => {
            upgrade_split::run_ctm_upgrade_prepare(args).await
        }
        EcosystemCommands::UpgradePrepareAll(args) => {
            upgrade_split::run_upgrade_prepare_all(args).await
        }
        EcosystemCommands::UpgradeGovernance(args) => upgrade::run_upgrade_governance(args).await,
    }
}
