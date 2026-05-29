//! Ecosystem-level commands.
//!
//! The v31 upgrade flow runs as Phase 1 (`UpgradePrepareAll`) → Phase 2
//! (`UpgradeGovernance`) → Phase 3 (`Stage3`) → Phase 4 (per-chain
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
    commands::ecosystem::stage3::Stage3Args,
    commands::ecosystem::upgrade::{ListCtmsArgs, UpgradeGovernanceArgs, UpgradePrepareAllArgs},
    commands::ecosystem::verify_upgrade::VerifyUpgradeArgs,
};

pub(crate) mod broadcast;
pub(crate) mod init;
pub(crate) mod new_gateway_prepare;
pub(crate) mod puh_guardians;
pub(crate) mod simulator;
pub(crate) mod stage3;
pub(crate) mod upgrade;
pub(crate) mod v31_upgrade_full;
pub(crate) mod v31_upgrade_inner;
pub(crate) mod verify_upgrade;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Phase 1 of the ecosystem upgrade: deploys all new ecosystem contracts
    /// (core + per-CTM impls + new ProtocolUpgradeHandler + new Guardians) on
    /// a single anvil fork, emits operational admin bundles for CTM-owned
    /// surfaces, and writes the merged `<out>/prepare/governance.toml` for
    /// Phase 2 to replay.
    #[command(name = "upgrade-prepare-all")]
    UpgradePrepareAll(UpgradePrepareAllArgs),
    /// Phase 2 of the ecosystem upgrade: replays governance stages 0+1+2 on
    /// a single anvil fork (governance owner signs). Emits one Safe bundle
    /// containing all three governance calls. Auto-discovers
    /// `<env>/prepare/governance.toml` when `--env` is set, or pass
    /// `--governance-toml` explicitly.
    #[command(name = "upgrade-governance")]
    UpgradeGovernance(UpgradeGovernanceArgs),
    /// Verify ecosystem upgrade artifacts produced by upgrade-prepare.
    #[command(name = "verify-upgrade")]
    VerifyUpgrade(VerifyUpgradeArgs),
    /// Broadcast the bundles produced by `upgrade-prepare-all` to a real (or
    /// fork) RPC under the supplied EOA keys. Multi-bundle dispatcher around
    /// `dev execute-safe`: reads `manifest.json`, replays each bundle in order
    /// signed by its declared `target`. Direct EOA broadcast — no Safe UI.
    #[command(name = "upgrade-broadcast")]
    UpgradeBroadcast(UpgradeBroadcastArgs),
    /// Phase 3 of the ecosystem upgrade: legacy-token registration. Calls
    /// `CoreUpgrade_v31.stage3(bridgehub)`, which registers ETH + every
    /// v31-bridged token in NTV's bridgedTokens list and calls
    /// `registerLegacyToken` on the L1AssetTracker (moves chainBalances out
    /// of the NTV). Runs *before* per-chain upgrades so each chain's
    /// withdrawals come back online as soon as its diamond upgrade lands.
    /// Any signer.
    Stage3(Stage3Args),
    /// Print a starter `--ctm-config` TOML by enumerating every CTM
    /// registered on the supplied bridgehub. Use this on stage / mainnet to
    /// discover the Atlas CTM address without having to look it up by hand.
    #[command(name = "list-ctms")]
    ListCtms(ListCtmsArgs),
    /// Convert a protocol-ops governance TOML into transaction-simulator JSON.
    #[command(name = "governance-toml-to-simulator")]
    GovernanceTomlToSimulator(GovernanceTomlToSimulatorArgs),
}

pub(crate) async fn run(args: EcosystemCommands) -> anyhow::Result<()> {
    match args {
        EcosystemCommands::Init(args) => init::run(args).await,
        EcosystemCommands::UpgradePrepareAll(args) => upgrade::run_upgrade_prepare_all(args).await,
        EcosystemCommands::UpgradeGovernance(args) => upgrade::run_upgrade_governance(args).await,
        EcosystemCommands::VerifyUpgrade(args) => verify_upgrade::run(args).await,
        EcosystemCommands::UpgradeBroadcast(args) => broadcast::run(args).await,
        EcosystemCommands::Stage3(args) => stage3::run(args).await,
        EcosystemCommands::ListCtms(args) => upgrade::run_list_ctms(args).await,
        EcosystemCommands::GovernanceTomlToSimulator(args) => simulator::run(args).await,
    }
}
