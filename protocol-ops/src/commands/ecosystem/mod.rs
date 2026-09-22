//! Ecosystem-level commands.
//!
//! The upgrade flow runs as Phase 1 (`UpgradePrepareAll`) → Phase 2
//! (`UpgradeGovernance`) → Phase 3 (per-chain
//! `Admin.upgradeChainFromVersion` in [`crate::commands::chain::upgrade`]).
//! Each `EcosystemCommands` variant carries the per-phase doc.
//!
//! Pre-flight (chains migrate off legacy GW back to L1) and the new GW
//! chain bring-up (`chain init` + `chain gateway convert`) are intentionally
//! kept outside this module — they're per-chain operations that don't share
//! the env-permanent shape.

use clap::Subcommand;

use crate::{
    commands::ecosystem::broadcast::UpgradeBroadcastArgs,
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::simulator::GovernanceTomlToSimulatorArgs,
    commands::ecosystem::upgrade::{ListCtmsArgs, UpgradeGovernanceArgs, UpgradePrepareAllArgs},
    commands::ecosystem::verify_bootstrap::VerifyBootstrapArgs,
};

pub mod broadcast;
pub mod init;
pub mod new_gateway_prepare;
pub mod simulator;
pub mod upgrade;
pub mod upgrade_full;
pub mod upgrade_inner;
pub mod verify_bootstrap;
pub mod zk_governance;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Phase 1 of the ecosystem upgrade: deploys all new ecosystem contracts
    /// (core + per-CTM impls + new zk-governance set) on
    /// a single anvil fork, emits operational admin bundles for CTM-owned
    /// surfaces, and writes the merged `<env-out>/ecosystem.toml` for
    /// Phase 2 to replay.
    #[command(name = "upgrade-prepare-all")]
    UpgradePrepareAll(UpgradePrepareAllArgs),
    /// Phase 2 of the ecosystem upgrade: replays governance stages 0+1+2 on
    /// a single anvil fork (governance owner signs). Emits one Safe bundle
    /// containing all three governance calls. Auto-discovers
    /// `<env-out>/ecosystem.toml` when `--env` is set, or pass
    /// `--governance-toml` explicitly.
    #[command(name = "upgrade-governance")]
    UpgradeGovernance(UpgradeGovernanceArgs),
    /// Verify a v34 registry-driven upgrade package — a recurring operation or the one-time
    /// bootstrap edge, decided from the package itself. Checks object provenance and
    /// construction, the authority binding and the owner it lands on, every proxy row's
    /// departing implementation, readiness, and that the governance calldata invokes the
    /// reviewed upgrade. Read-only.
    #[command(name = "verify-bootstrap", visible_alias = "verify-package")]
    VerifyBootstrap(VerifyBootstrapArgs),
    /// Broadcast the bundles produced by `upgrade-prepare-all` to a real (or
    /// fork) RPC under the supplied EOA keys. Multi-bundle dispatcher around
    /// `dev execute-safe`: reads `manifest.json`, replays each bundle in order
    /// signed by its declared `target`. Direct EOA broadcast — no Safe UI.
    #[command(name = "upgrade-broadcast")]
    UpgradeBroadcast(UpgradeBroadcastArgs),
    /// Print a starter `--ctm-config` TOML by enumerating every CTM
    /// registered on the supplied bridgehub. Use this on stage / mainnet to
    /// discover the Atlas CTM address without having to look it up by hand.
    #[command(name = "list-ctms")]
    ListCtms(ListCtmsArgs),
    /// Convert a protocol-ops governance TOML into transaction-simulator JSON.
    #[command(name = "governance-toml-to-simulator")]
    GovernanceTomlToSimulator(GovernanceTomlToSimulatorArgs),
}

pub async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::UpgradePrepareAll(args) => upgrade::run_upgrade_prepare_all(args).await,
        EcosystemCommands::UpgradeGovernance(args) => upgrade::run_upgrade_governance(args).await,
        EcosystemCommands::VerifyBootstrap(args) => verify_bootstrap::run(args).await,
        EcosystemCommands::UpgradeBroadcast(args) => broadcast::run(args).await,
        EcosystemCommands::ListCtms(args) => upgrade::run_list_ctms(args).await,
        EcosystemCommands::GovernanceTomlToSimulator(args) => simulator::run(args).await,
    }
}
