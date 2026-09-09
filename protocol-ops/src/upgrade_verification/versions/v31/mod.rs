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

// Target protocol versions, per CTM flavour. Each CTM upgrades to its own
// flavour's chain-creation `latestProtocolVersion`, which comes from that
// flavour's genesis config — `DefaultCTMUpgrade.getNewProtocolVersion()` returns
// `config.contracts.chainCreationParams.latestProtocolVersion`. The two
// flavours' genesis lines moved independently, so a single shared constant
// cannot describe both: this branch ships Era genesis v0.32.2 (see the
// `old_protocol_version` note in `upgrade-envs/v0.31.0-interopB/
// foundry-upgrade.toml`) and ZKsync-OS genesis v0.31.2.
pub(crate) const EXPECTED_ERA_NEW_PROTOCOL_VERSION_STR: &str = "0.32.2";
pub(crate) const EXPECTED_ZKSYNC_OS_NEW_PROTOCOL_VERSION_STR: &str = "0.31.2";
// Source protocol versions, per CTM flavour: the version each CTM is on when
// v31 executes, checked against both the artifact's `old_protocol_version` and
// the live CTM's `protocolVersion()`.
//
// Era is v0.30.1, not the v0.29.4 the July calldata was cut against. Mainnet's
// Era CTM moved to v0.30.1 at block 25766158 — after that calldata was
// generated and 268k blocks after its contracts were deployed — so the recorded
// ceremony would revert (`setNewVersionUpgrade old protocol version mismatch`)
// and the re-cut upgrades Era from v0.30.1.
// Source line each flavour upgrades from, as (major, minor) per environment.
//
// The patch digit is deliberately not pinned. It described a live CTM, so every
// patch bump on someone else's chain made a pinned value wrong: ADI's ZKsync-OS
// CTM went v0.30.1 -> v0.30.2 at block 25926020 and its calldata could no longer
// be verified, while nothing about whether v31 applies had changed. Pinning the
// patch is what made this table go stale three times.
//
// The minor still has to be per-environment, because the fleet genuinely
// disagrees: mainnet's Era CTM is on the v0.30 line, testnet's is still on v0.29.
// The artifact's own `old_protocol_version` is separately compared against the
// live CTM, which is the stronger check; this table exists to catch v31 tooling
// pointed at an ecosystem nowhere near the v0.30 line at all.
const EXPECTED_ERA_OLD_PROTOCOL_LINE: (u64, u64) = (0, 30);
const EXPECTED_ERA_OLD_PROTOCOL_LINE_TESTNET: (u64, u64) = (0, 29);
const EXPECTED_ZKSYNC_OS_OLD_PROTOCOL_LINE: (u64, u64) = (0, 30);
pub(crate) const MAX_NUMBER_OF_ZK_CHAINS: u32 = 100;
pub(crate) const MAX_PRIORITY_TX_GAS_LIMIT: u32 = 72_000_000;

/// Stage Sepolia's Era chain (270) is the single registered chain still
/// settling on the legacy stage Gateway at v31 upgrade time.
/// `L1MessageRootStageSepolia._v31InitializeInner` skips it (see
/// `l1-contracts/contracts/dev-contracts/L1MessageRootStageSepolia.sol`),
/// so PUVT must apply the same skip when pre-flighting the
/// `Bridgehub.settlementLayer(chainId) == L1` invariant on stage.
pub(crate) const STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID: u64 = 270;

pub(crate) fn get_expected_new_protocol_version_for_ctm_flavor(
    flavor: CtmFlavor,
) -> ProtocolVersion {
    let version = match flavor {
        CtmFlavor::Era => EXPECTED_ERA_NEW_PROTOCOL_VERSION_STR,
        CtmFlavor::ZksyncOs => EXPECTED_ZKSYNC_OS_NEW_PROTOCOL_VERSION_STR,
    };
    ProtocolVersion::from_str(version).unwrap()
}

/// The `(major, minor)` line the given env's CTM of this flavour upgrades from.
pub(crate) fn expected_old_protocol_line(env: VerifyUpgradeEnv, flavor: CtmFlavor) -> (u64, u64) {
    match (env, flavor) {
        (VerifyUpgradeEnv::Testnet, CtmFlavor::Era) => EXPECTED_ERA_OLD_PROTOCOL_LINE_TESTNET,
        (_, CtmFlavor::Era) => EXPECTED_ERA_OLD_PROTOCOL_LINE,
        (_, CtmFlavor::ZksyncOs) => EXPECTED_ZKSYNC_OS_OLD_PROTOCOL_LINE,
    }
}

/// Human-readable form of [`expected_old_protocol_line`], e.g. `v0.30.x`.
pub(crate) fn expected_old_protocol_line_label(env: VerifyUpgradeEnv, flavor: CtmFlavor) -> String {
    let (major, minor) = expected_old_protocol_line(env, flavor);
    format!("v{major}.{minor}.x")
}

/// Whether `version` sits on the source line [`expected_old_protocol_line`] names.
/// Compares `(major, minor)` only — see the constants for why the patch is free.
pub(crate) fn is_expected_old_protocol_version_for_ctm_flavor(
    version: ProtocolVersion,
    env: VerifyUpgradeEnv,
    flavor: CtmFlavor,
) -> bool {
    (version.major, version.minor) == expected_old_protocol_line(env, flavor)
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
    // load-bearing deployment is missing.
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

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> ProtocolVersion {
        ProtocolVersion::from_str(s).unwrap()
    }

    /// The fleet does not agree on one source line per flavour: mainnet's Era CTM
    /// is on v0.30, testnet's is still on v0.29. A single per-flavour constant
    /// cannot describe both, which is what made the testnet rehearsal fail its own
    /// gate the moment the constant was moved for mainnet.
    #[test]
    fn the_era_source_line_is_per_environment() {
        assert!(is_expected_old_protocol_version_for_ctm_flavor(
            v("0.29.4"),
            VerifyUpgradeEnv::Testnet,
            CtmFlavor::Era
        ));
        assert!(is_expected_old_protocol_version_for_ctm_flavor(
            v("0.30.1"),
            VerifyUpgradeEnv::Mainnet,
            CtmFlavor::Era
        ));
        // ... and each rejects the other's line.
        assert!(!is_expected_old_protocol_version_for_ctm_flavor(
            v("0.30.1"),
            VerifyUpgradeEnv::Testnet,
            CtmFlavor::Era
        ));
        assert!(!is_expected_old_protocol_version_for_ctm_flavor(
            v("0.29.4"),
            VerifyUpgradeEnv::Mainnet,
            CtmFlavor::Era
        ));
    }

    /// A patch bump on a live CTM must not invalidate the calldata. ADI's ZKsync-OS
    /// CTM went v0.30.1 -> v0.30.2 at block 25926020, which under a pinned patch
    /// digit meant its calldata could no longer be verified even though nothing
    /// about whether v31 applies had changed.
    #[test]
    fn a_patch_bump_stays_on_the_same_source_line() {
        for env in [VerifyUpgradeEnv::Adi, VerifyUpgradeEnv::Mainnet] {
            for version in ["0.30.0", "0.30.1", "0.30.2", "0.30.9"] {
                assert!(
                    is_expected_old_protocol_version_for_ctm_flavor(
                        v(version),
                        env,
                        CtmFlavor::ZksyncOs
                    ),
                    "{env:?} should accept ZKsync-OS {version}"
                );
            }
            // A different minor is still a different line.
            assert!(!is_expected_old_protocol_version_for_ctm_flavor(
                v("0.29.4"),
                env,
                CtmFlavor::ZksyncOs
            ));
        }
    }

    #[test]
    fn the_line_label_names_the_free_patch() {
        assert_eq!(
            expected_old_protocol_line_label(VerifyUpgradeEnv::Adi, CtmFlavor::ZksyncOs),
            "v0.30.x"
        );
        assert_eq!(
            expected_old_protocol_line_label(VerifyUpgradeEnv::Testnet, CtmFlavor::Era),
            "v0.29.x"
        );
    }
}
