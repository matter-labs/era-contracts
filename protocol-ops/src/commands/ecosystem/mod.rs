//! Ecosystem-level commands. The v31 upgrade flow lives entirely under here:
//!
//! ```text
//! Phase 1  ecosystem upgrade-prepare-all   (deployer EOA + Atlas-CTM-owner Safe)
//!     ├── CoreUpgrade_v31.noGovernancePrepare        (deploy core L1 contracts)
//!     ├── CTMUpgrade_v31.noGovernancePrepare         (per --ctm-proxy)
//!     └── DeployPUHAndGuardians                       (zk-governance redeploy)
//!     emits: <out>/prepare/governance.toml            (merged stage 0/1/2 calls,
//!                                                      including the PUH+Guardians
//!                                                      stage-0 calls)
//!     emits: <out>/prepare/NN_*.safe.json             (per-signer deployer/EOA bundles)
//!
//! Phase 2  ecosystem upgrade-governance    (governance owner / PUH signs)
//!     replays stages 0/1/2 from the merged governance.toml
//!
//! Phase 3  chain upgrade                   (each chain admin signs separately)
//!     `Admin.upgradeChainFromVersion(...)` per registered ZK chain. Pass
//!     `--chain-id` to target one chain; omit to loop over every registered
//!     chain on the bridgehub.
//!
//! Phase 4  ecosystem stage3                (any signer)
//!     post-governance bridged-token migration: registers ETH + every entry
//!     in the v31-bridged-tokens config in NTV's bridgedTokens list and
//!     migrates non-zero `chainBalance` entries into the L1AssetTracker.
//! ```
//!
//! Pre-flight (chains migrate off legacy GW back to L1) and the new GW
//! chain bring-up (`chain init` + `chain gateway convert`) are intentionally
//! kept outside this module — they're per-chain operations that don't share
//! the env-permanent shape.

use clap::Subcommand;

use crate::{
    commands::ecosystem::init::EcosystemInitArgs,
    commands::ecosystem::simulator::GovernanceTomlToSimulatorArgs,
    commands::ecosystem::stage3::Stage3Args,
    commands::ecosystem::upgrade::{ListCtmsArgs, UpgradeGovernanceArgs, UpgradePrepareAllArgs},
};

pub(crate) mod init;
pub(crate) mod puh_guardians;
pub(crate) mod simulator;
pub(crate) mod stage3;
pub(crate) mod upgrade;
pub(crate) mod v31_upgrade_full;
pub(crate) mod v31_upgrade_inner;

#[derive(Subcommand, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EcosystemCommands {
    /// Initialize ecosystem
    Init(EcosystemInitArgs),
    /// Phase 1 of the ecosystem upgrade: deploys all new ecosystem contracts
    /// (core + per-CTM impls + new ProtocolUpgradeHandler + new Guardians) on
    /// a single anvil fork, signed by the deployer EOA, and emits the merged
    /// `<out>/prepare/governance.toml` for Phase 2 to replay.
    #[command(name = "upgrade-prepare-all")]
    UpgradePrepareAll(UpgradePrepareAllArgs),
    /// Phase 2 of the ecosystem upgrade: replays governance stages 0+1+2 on
    /// a single anvil fork (governance owner signs). Emits one Safe bundle
    /// containing all three governance calls. Auto-discovers
    /// `<env>/prepare/governance.toml` when `--env` is set, or pass
    /// `--governance-toml` explicitly.
    #[command(name = "upgrade-governance")]
    UpgradeGovernance(UpgradeGovernanceArgs),
    /// Phase 4 of the ecosystem upgrade: post-governance bridged-token
    /// migration. Calls `CoreUpgrade_v31.stage3(bridgehub)`, which registers
    /// ETH + every v31-bridged token in NTV's bridgedTokens list and
    /// migrates non-zero chainBalance entries into L1AssetTracker. Any signer.
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
        EcosystemCommands::Stage3(args) => stage3::run(args).await,
        EcosystemCommands::ListCtms(args) => upgrade::run_list_ctms(args).await,
        EcosystemCommands::GovernanceTomlToSimulator(args) => simulator::run(args).await,
    }
}
