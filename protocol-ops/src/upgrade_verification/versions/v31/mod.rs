// TODO: drop once the scaffolding kept for R2 (fee-params) and S2d
// (`check_gw_create2_deploy`) is resolved.
#![allow(dead_code, private_interfaces)]

use std::str::FromStr;

use alloy::primitives::{Address, FixedBytes, U256};

use crate::{
    commands::ecosystem::verify_upgrade::VerifyUpgradeEnv,
    common::env_config::ChainInterval,
    upgrade_verification::{
        artifacts::{CtmFlavor, EcosystemUpgradeArtifact},
        verifiers::{VerificationResult, Verifiers},
    },
};

pub(crate) mod elements;
pub(crate) mod utils;

use elements::{
    deployed_addresses::verify_v31_provenance,
    governance_stage_calls::{verify_governance_stage_calls, verify_per_chain_protocol_versions},
    protocol_version::ProtocolVersion,
    rpc_state::verify_v31_artifact_state,
};

/// Protocol versions a v31 ceremony moves a CTM between, per environment and
/// CTM flavour. The source side is checked against both the artifact's
/// `old_protocol_version` and the live CTM's `protocolVersion()`; the target
/// side against the artifact's `new_protocol_version`.
///
/// A ceremony generated from this branch targets each flavour's genesis
/// `protocol_semantic_version` (`configs/genesis/<flavour>/latest.json`, which
/// `DefaultCTMUpgrade.getNewProtocolVersion()` reads through
/// `chainCreationParams`): Era v0.33.0, ZKsync OS v0.31.2. The two genesis
/// lines moved independently, so one shared target cannot describe both.
///
/// The environments do not share one table either:
///
/// * Mainnet's Era CTM moved to v0.30.1 at block 25766158, after the July
///   calldata was cut, so the recorded ceremony would revert
///   (`setNewVersionUpgrade old protocol version mismatch`) and mainnet was
///   re-cut from v0.30.1 against this branch's genesis. Its ceremony has not
///   executed: exactly one target is acceptable.
/// * ADI is a ZKsync-OS-only ecosystem on L1 mainnet, cut from the same branch.
/// * Sepolia (testnet, stage) already executed v31 from the July calldata —
///   Era v0.29.4 → v0.31.0, ZKsync OS v0.30.1 → v0.31.0 — and their committed
///   artifacts record that ceremony. A fresh rehearsal of those envs from this
///   branch (the CI regen job forks Sepolia before the upgrade) targets the
///   branch genesis instead; it is a tooling smoke test, not a ceremony that
///   will run, so both targets are accepted there.
///
/// `tests::expected_versions_match_committed_artifacts` pins the table to the
/// committed `output/<env>/ecosystem.toml` files, and
/// `tests::branch_genesis_targets_match_genesis_configs` to the genesis files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExpectedProtocolVersions {
    /// The version the CTM must be on when the ceremony executes.
    pub(crate) old: ProtocolVersion,
    /// Targets the artifact may declare (see above); never empty.
    pub(crate) new: Vec<ProtocolVersion>,
}

impl ExpectedProtocolVersions {
    pub(crate) fn accepts_new(&self, version: ProtocolVersion) -> bool {
        self.new.contains(&version)
    }

    /// The accepted targets for an error message, e.g. `0.31.0 or 0.33.0`.
    pub(crate) fn describe_new(&self) -> String {
        self.new
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(" or ")
    }
}

/// Each flavour's genesis `protocol_semantic_version` on this branch: what a
/// ceremony generated here targets.
/// Era is v0.33.0 so mainnet lands on the same label as stage, which receives
/// this bootloader (zksolc 1.5.17 + DSE root-frame hooks) as its own v0.33.0.
const BRANCH_GENESIS_ERA_PROTOCOL_VERSION: &str = "0.33.0";
const BRANCH_GENESIS_ZKSYNC_OS_PROTOCOL_VERSION: &str = "0.31.2";
/// What Sepolia (testnet, stage) executed v31 as, from the July calldata.
const SEPOLIA_EXECUTED_V31_PROTOCOL_VERSION: &str = "0.31.0";
/// Sepolia's source versions at execution: Era CTM v0.29.4, ZKsync OS CTM v0.30.1.
const SEPOLIA_ERA_SOURCE_PROTOCOL_VERSION: &str = "0.29.4";
const SEPOLIA_ZKSYNC_OS_SOURCE_PROTOCOL_VERSION: &str = "0.30.1";
/// Both mainnet CTMs (and ADI's) are on v0.30.1 when v31 executes.
const MAINNET_SOURCE_PROTOCOL_VERSION: &str = "0.30.1";

pub(crate) fn expected_protocol_versions(
    env: VerifyUpgradeEnv,
    flavor: CtmFlavor,
) -> ExpectedProtocolVersions {
    let branch_genesis = match flavor {
        CtmFlavor::Era => BRANCH_GENESIS_ERA_PROTOCOL_VERSION,
        CtmFlavor::ZksyncOs => BRANCH_GENESIS_ZKSYNC_OS_PROTOCOL_VERSION,
    };
    let (old, new): (&str, Vec<&str>) = match (env, flavor) {
        (VerifyUpgradeEnv::Stage | VerifyUpgradeEnv::Testnet, CtmFlavor::Era) => (
            SEPOLIA_ERA_SOURCE_PROTOCOL_VERSION,
            vec![SEPOLIA_EXECUTED_V31_PROTOCOL_VERSION, branch_genesis],
        ),
        (VerifyUpgradeEnv::Stage | VerifyUpgradeEnv::Testnet, CtmFlavor::ZksyncOs) => (
            SEPOLIA_ZKSYNC_OS_SOURCE_PROTOCOL_VERSION,
            vec![SEPOLIA_EXECUTED_V31_PROTOCOL_VERSION, branch_genesis],
        ),
        (VerifyUpgradeEnv::Mainnet | VerifyUpgradeEnv::Adi, _) => {
            (MAINNET_SOURCE_PROTOCOL_VERSION, vec![branch_genesis])
        }
    };
    let parse = |v: &str| ProtocolVersion::from_str(v).expect("protocol version literal");
    ExpectedProtocolVersions {
        old: parse(old),
        new: new.into_iter().map(parse).collect(),
    }
}

/// CREATE2 deployments PUVT recognizes in an env's transactions logs that this upgrade does not
/// use: contracts of earlier broadcasts (the July 2026 deployment kept as the reference log, and
/// the 2026-09-07 broadcast whose contracts the re-cut bundle superseded). No element expects
/// them, so no constructor check applies. For an env with a list, any other unchecked CREATE2
/// deployment is an error (`report_unverified_create2_deployments`); envs without one keep the
/// warning until a real run enumerates theirs.
///
/// `tests::mainnet_historical_create2_deployments_are_unused_by_the_upgrade` pins the mainnet
/// list against the committed ecosystem TOML.
pub(crate) fn historical_create2_deployments(env: VerifyUpgradeEnv) -> Option<&'static [Address]> {
    match env {
        VerifyUpgradeEnv::Mainnet => Some(&MAINNET_HISTORICAL_CREATE2_DEPLOYMENTS),
        VerifyUpgradeEnv::Stage | VerifyUpgradeEnv::Testnet | VerifyUpgradeEnv::Adi => None,
    }
}

/// The 2026-10-06 live mainnet PUVT (the full deployer journal plus the July reference log)
/// found these 17 besides the upgrade's own deployments; the generation and handoff runs of
/// 36548947871 find 10 of them.
const MAINNET_HISTORICAL_CREATE2_DEPLOYMENTS: [Address; 17] = [
    alloy::primitives::address!("0x1b5706059A887630Db7f3D62B7C1577bb032f6E8"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0x36f23a378233Db0bFB9A243711a98d846D40521C"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0x37e3343831dbd4997f4283f8d1A8991091befC95"), // EIP7702Checker
    alloy::primitives::address!("0x6A195c351EcCAE69165c0fD202095C4abdf1c197"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0x787C1F9CF40EF0bd852a9Bc571Bc3e3010Cf79B1"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0x7f60f575640E658CC2A400d59307f90fdEa05176"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0x8eF17384A157287921E1ebdb0a08a2f102ba4a92"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xA17E687F56F6E8d892e3D6e3427eA14AdFefF1Cb"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xA4AD3d2621F1d2B737d35a9c2E361D704cb8d3aF"), // RollupL1DAValidator
    alloy::primitives::address!("0xAE273354E73714bC5Fb7b15c02c2bC0Dc03b4c5E"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xE5d0a1CbAA5a65e76956B1c094fBB838B48841a2"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xbd44a86d1469751cf173bcc00162748E8Ac6739A"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xc2fc8952e3fF43c93369ce9f6517ED6dfC663137"), // EIP7702Checker
    alloy::primitives::address!("0xd3a6C81d2F080b223f41ebdd3F7AD2BbeFD57B90"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xe33cc25e7f9275cdcb65CAfb85c3215d45003C12"), // ZKsyncOSVerifierFflonk
    alloy::primitives::address!("0xe8536Ff0bf73E9245Ce5bF58b7e06388Fe9dBD52"), // TransparentUpgradeableProxy
    alloy::primitives::address!("0xff216E1b4e38A9206721795cE4Ab5F76d1Dd1140"), // RollupL1DAValidator
];

pub(crate) const MAX_NUMBER_OF_ZK_CHAINS: u32 = 100;
pub(crate) const MAX_PRIORITY_TX_GAS_LIMIT: u32 = 72_000_000;

/// Stage Sepolia's Era chain (270) is the single registered chain still
/// settling on the legacy stage Gateway at v31 upgrade time.
/// `L1MessageRootStageSepolia._v31InitializeInner` skips it (see
/// `l1-contracts/contracts/dev-contracts/L1MessageRootStageSepolia.sol`),
/// so PUVT must apply the same skip when pre-flighting the
/// `Bridgehub.settlementLayer(chainId) == L1` invariant on stage.
pub(crate) const STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID: u64 = 270;

pub(crate) fn get_expected_old_protocol_version(
    env: VerifyUpgradeEnv,
    flavor: CtmFlavor,
) -> ProtocolVersion {
    expected_protocol_versions(env, flavor).old
}

/// Run the full v31 verification pipeline.
///
/// Ordering mirrors the legacy PUVT (`UpgradeOutput::verify` in
/// `protocol-upgrade-verification-tool`):
///
///   1. Verifier construction (incl. SystemConfig.json fee-params init).
///   2. CREATE2 provenance map population — v31-specific prep that must precede
///      provenance consumption below.
///   3. RPC state checks — chain ids, Create2Factory bytecode, proxy admins,
///      live core wiring, validator timelocks, fee params, settlement layer.
///      Subsumes legacy's early chain-id sanity (legacy steps 2–3).
///   4. Deployment provenance — every named v31 deploy + the new-GW CTM
///      provenance flow (legacy step 4).
///   5. Per-chain protocol-version sweep — was bundled inside legacy
///      `deployed_addresses.verify`; sits next to provenance for the same
///      reason.
///   6. Stage 0 / 1 / 2 governance calls (legacy steps 7–9). Last.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify(
    env: VerifyUpgradeEnv,
    artifact: &EcosystemUpgradeArtifact,
    l1_rpc_url: &str,
    gw_rpc_url: Option<&str>,
    contracts_commit: Option<&str>,
    zk_governance_commit: &str,
    era_chain_id: u64,
    legacy_era_chain_id: u64,
    legacy_gateway_chain_id: u64,
    legacy_gateway_chain_intervals: &[ChainInterval],
    new_gateway_chain_id: u64,
    new_gateway_representative_chain_id: u64,
    new_gateway_settlement_fee: U256,
    l1_chain_id: u64,
    tx_hashes: &[FixedBytes<32>],
    // A prior regen's already-broadcast deployment log. Only enriches the
    // address book — exempt from the salt gate, since its deploys carry that
    // regen's (now-rotated) salts.
    reference_tx_hashes: &[FixedBytes<32>],
    create2_factory: Address,
    expected_salts: &[FixedBytes<32>],
    zk_token_asset_id: FixedBytes<32>,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== Config verification ==");
    let mut verifiers = Verifiers::new_v31(
        env,
        artifact,
        l1_rpc_url,
        gw_rpc_url.map(str::to_string),
        contracts_commit,
        zk_governance_commit,
        era_chain_id,
        legacy_era_chain_id,
        legacy_gateway_chain_id,
        legacy_gateway_chain_intervals,
        new_gateway_chain_id,
        new_gateway_representative_chain_id,
        new_gateway_settlement_fee,
        l1_chain_id,
        zk_token_asset_id,
    )
    .await?;
    result.report_ok(&format!(
        "v31 verifier context loaded with {} named addresses",
        verifiers.address_verifier.name_to_address.len()
    ));
    match verifiers.network_verifier.get_gateway_chain_id() {
        Some(chain_id) => result.report_ok(&format!("Gateway RPC chain ID: {chain_id}")),
        None => result.report_ok("Gateway RPC: none (gateway-less env)"),
    }

    // Populate the create2 maps so deployment provenance can match
    // deployed addresses against expected init bytecode + constructor args.
    // Each tx is fetched from L1 RPC; stale entries (whose bytecode no longer
    // matches AllContractsHashes after a regen) are silently skipped — the
    // address-book lookup in `expect_create2_params` hard-errors only if a
    // load-bearing deployment is missing. Entries the RPC cannot return even
    // after retries are reported, as errors in an env with a historical list
    // (see `historical_create2_deployments`), since the coverage check could
    // not see their deployments.
    let strict_fetch = historical_create2_deployments(verifiers.env).is_some();
    let count = {
        let bridgehub_address = verifiers.bridgehub_address;
        let Verifiers {
            bytecode_verifier,
            network_verifier,
            ..
        } = &mut verifiers;
        // This run's own log first, salt-gated: a prepare that missed its
        // config salt and fell back to a random one must fail here.
        network_verifier
            .populate_create2_from_transactions_log(
                tx_hashes,
                &create2_factory,
                &bridgehub_address,
                expected_salts,
                true,
                strict_fetch,
                bytecode_verifier,
                result,
            )
            .await;
        // Then the reference log, ungated (see `reference_tx_hashes`).
        network_verifier
            .populate_create2_from_transactions_log(
                reference_tx_hashes,
                &create2_factory,
                &bridgehub_address,
                expected_salts,
                false,
                strict_fetch,
                bytecode_verifier,
                result,
            )
            .await;
        network_verifier.create2_known_bytecodes.len()
    };
    result.report_ok(&format!(
        "Loaded {} CREATE2 deployments from transactions log",
        count,
    ));

    verify_v31_artifact_state(artifact, &verifiers, create2_factory, result).await?;

    // Deployment provenance verifies the core withdrawal contracts
    // (L1AssetRouter/L1Nullifier/MailboxFacet), whose `eraChainId` ctor arg is
    // the LEGACY era (270 on split-era testnet), not the registered era.
    verify_v31_provenance(
        artifact,
        &verifiers,
        legacy_era_chain_id,
        legacy_gateway_chain_id,
        result,
    )
    .await?;

    verify_per_chain_protocol_versions(artifact, &verifiers, result).await?;

    verify_governance_stage_calls(artifact, &verifiers, result).await?;

    // Last, so it sees every expectation the elements above registered.
    result.report_unverified_create2_deployments(
        &verifiers,
        historical_create2_deployments(verifiers.env),
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::paths::path_from_root;

    /// The per-env table must accept the ceremonies the committed artifacts
    /// record; a regen that moves a version has to update both.
    #[test]
    fn expected_versions_match_committed_artifacts() {
        for (env, dir) in [
            (VerifyUpgradeEnv::Stage, "stage"),
            (VerifyUpgradeEnv::Testnet, "testnet"),
            (VerifyUpgradeEnv::Mainnet, "mainnet"),
        ] {
            let path = path_from_root(format!(
                "l1-contracts/upgrade-envs/v0.31.0-interopB/output/{dir}/ecosystem.toml"
            ));
            let artifact = EcosystemUpgradeArtifact::read(&path)
                .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
            assert!(!artifact.ctms.is_empty(), "{dir}: artifact lists no CTMs");
            for ctm in &artifact.ctms {
                let expected = expected_protocol_versions(env, ctm.flavor);
                assert_eq!(
                    ProtocolVersion::from(U256::from(ctm.contracts_config.old_protocol_version)),
                    expected.old,
                    "{dir} {} old_protocol_version",
                    ctm.flavor.label()
                );
                let new =
                    ProtocolVersion::from(U256::from(ctm.contracts_config.new_protocol_version));
                assert!(
                    expected.accepts_new(new),
                    "{dir} {} new_protocol_version {new} is not one of {}",
                    ctm.flavor.label(),
                    expected.describe_new()
                );
            }
        }
    }

    /// The branch-genesis targets are what `DefaultCTMUpgrade.getNewProtocolVersion()`
    /// reads from `configs/genesis/<flavour>/latest.json`; if a genesis line moves,
    /// this table must move with it. Mainnet's single target IS the branch genesis;
    /// the executed Sepolia envs accept it next to their executed version.
    ///
    /// A later release line (e.g. `draft-v34-era-only`, Era genesis v0.34.0) carries
    /// its own genesis on a newer minor. v31 ceremonies are cut from `draft-v31`, not
    /// from such a line, so a flavour whose genesis has moved to a newer minor is
    /// skipped here; `expected_versions_match_committed_artifacts` still pins the table.
    #[test]
    fn branch_genesis_targets_match_genesis_configs() {
        for (dir, flavor) in [("era", CtmFlavor::Era), ("zksync-os", CtmFlavor::ZksyncOs)] {
            let path = path_from_root(format!("configs/genesis/{dir}/latest.json"));
            let raw = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
            let json: serde_json::Value =
                serde_json::from_str(&raw).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
            let semver = &json["protocol_semantic_version"];
            let genesis = ProtocolVersion {
                major: semver["major"]
                    .as_u64()
                    .expect("protocol_semantic_version.major"),
                minor: semver["minor"]
                    .as_u64()
                    .expect("protocol_semantic_version.minor"),
                patch: semver["patch"]
                    .as_u64()
                    .expect("protocol_semantic_version.patch"),
            };
            let v31_target = match flavor {
                CtmFlavor::Era => BRANCH_GENESIS_ERA_PROTOCOL_VERSION,
                CtmFlavor::ZksyncOs => BRANCH_GENESIS_ZKSYNC_OS_PROTOCOL_VERSION,
            };
            let v31_target = ProtocolVersion::from_str(v31_target).unwrap();
            if (genesis.major, genesis.minor) > (v31_target.major, v31_target.minor) {
                continue;
            }
            assert_eq!(
                expected_protocol_versions(VerifyUpgradeEnv::Mainnet, flavor).new,
                vec![genesis],
                "{dir}: mainnet must target exactly the branch genesis"
            );
            for env in [VerifyUpgradeEnv::Stage, VerifyUpgradeEnv::Testnet] {
                let expected = expected_protocol_versions(env, flavor);
                assert!(
                    expected.accepts_new(genesis),
                    "{dir}: {} must accept a fresh rehearsal's target {genesis}",
                    env.as_str()
                );
                assert!(
                    expected.accepts_new(
                        ProtocolVersion::from_str(SEPOLIA_EXECUTED_V31_PROTOCOL_VERSION).unwrap()
                    ),
                    "{dir}: {} must accept its executed ceremony's target",
                    env.as_str()
                );
            }
        }
    }

    /// ADI ships no Era CTM and is cut from mainnet's branch: same ZKsync OS pair.
    #[test]
    fn adi_follows_mainnet() {
        assert_eq!(
            expected_protocol_versions(VerifyUpgradeEnv::Adi, CtmFlavor::ZksyncOs),
            expected_protocol_versions(VerifyUpgradeEnv::Mainnet, CtmFlavor::ZksyncOs)
        );
    }

    /// The mainnet list may only hold contracts the upgrade does not use: none of them appears
    /// anywhere in the committed mainnet ecosystem TOML, as an address or inside calldata. It has
    /// no duplicates, and the other envs have no list yet.
    #[test]
    fn mainnet_historical_create2_deployments_are_unused_by_the_upgrade() {
        let toml = std::fs::read_to_string(path_from_root(
            "l1-contracts/upgrade-envs/v0.31.0-interopB/output/mainnet/ecosystem.toml",
        ))
        .unwrap()
        .to_lowercase();
        let list = historical_create2_deployments(VerifyUpgradeEnv::Mainnet).unwrap();
        let unique: std::collections::BTreeSet<_> = list.iter().collect();
        assert_eq!(unique.len(), list.len(), "duplicate entries");
        for address in list {
            assert!(
                !toml.contains(&alloy::hex::encode(address.as_slice())),
                "{address} is used by the mainnet upgrade, so it is not historical"
            );
        }
        for env in [
            VerifyUpgradeEnv::Stage,
            VerifyUpgradeEnv::Testnet,
            VerifyUpgradeEnv::Adi,
        ] {
            assert!(historical_create2_deployments(env).is_none());
        }
    }
}
