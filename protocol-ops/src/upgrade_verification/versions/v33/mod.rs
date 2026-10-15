// The v31 verifier still carries helpers and artifact mirrors nothing reads on this branch, and
// `Verifiers` / `VerificationResult` are `pub(crate)` but flow through `pub` element methods;
// both are a separate cleanup.
#![allow(dead_code, private_interfaces)]

use std::str::FromStr;

use alloy::primitives::{Address, FixedBytes};

use crate::{
    commands::ecosystem::verify_upgrade::VerifyUpgradeEnv,
    upgrade_verification::{
        artifacts::{CtmFlavor, EcosystemUpgradeArtifact},
        verifiers::{VerificationResult, Verifiers},
    },
};

pub(crate) mod elements;
pub(crate) mod utils;

use elements::{
    ctm_admin_calls::verify_ctm_admin_calls,
    deployed_addresses::verify_v33_provenance,
    governance_stage_calls::{verify_governance_stage_calls, verify_per_chain_protocol_versions},
    protocol_version::ProtocolVersion,
    rpc_state::verify_v33_artifact_state,
};

pub(crate) const EXPECTED_ZKSYNC_OS_OLD_PROTOCOL_VERSION_STR: &str = "0.34.0";
/// CREATE2 deployments PUVT recognizes in an env's transactions logs that this upgrade does not
/// use: contracts of earlier broadcasts kept in a reference log. No element expects them, so no
/// constructor check applies. For an env with a list, any other unchecked CREATE2 deployment is
/// an error (`report_unverified_create2_deployments`), and transactions-log entries the RPC
/// cannot return are errors too; envs without one keep both as warnings.
///
/// No environment has had a real run enumerate its historical deployments yet, so every env
/// is on the warning path. Add an env's list here once one has.
pub(crate) fn historical_create2_deployments(_env: VerifyUpgradeEnv) -> Option<&'static [Address]> {
    None
}

pub(crate) const MAX_NUMBER_OF_ZK_CHAINS: u32 = 100;

pub(crate) fn get_expected_new_protocol_version(verifiers: &Verifiers) -> ProtocolVersion {
    verifiers.zksync_os_genesis_config.protocol_semantic_version
}

pub(crate) fn get_expected_old_protocol_version_for_ctm_flavor(
    flavor: CtmFlavor,
) -> ProtocolVersion {
    let version = match flavor {
        CtmFlavor::ZksyncOs => EXPECTED_ZKSYNC_OS_OLD_PROTOCOL_VERSION_STR,
    };
    ProtocolVersion::from_str(version).unwrap()
}

/// Whether `version` is the release this upgrade starts from.
///
/// Compares major.minor and ignores the patch: a CTM sitting on a patch release of the source
/// version (e.g. v0.34.1) is still on v34, and this upgrade applies to
/// it unchanged — the diamond cut is keyed on the CTM's own reported version, not on a pinned
/// patch. Requiring an exact match rejected a legitimately-patched ecosystem.
pub(crate) fn is_expected_old_protocol_version_for_ctm_flavor(
    version: ProtocolVersion,
    flavor: CtmFlavor,
) -> bool {
    let expected = get_expected_old_protocol_version_for_ctm_flavor(flavor);
    version.major == expected.major && version.minor == expected.minor
}

pub(crate) fn expected_old_protocol_version_label(flavor: CtmFlavor) -> &'static str {
    match flavor {
        CtmFlavor::ZksyncOs => "v0.34.x",
    }
}

/// Run the full v33 verification pipeline.
///
/// Ordering mirrors the legacy PUVT (`UpgradeOutput::verify` in
/// `protocol-upgrade-verification-tool`):
///
///   1. Verifier construction.
///   2. CREATE2 provenance map population — upgrade-specific prep that must precede
///      provenance consumption below.
///   3. RPC state checks — chain ids, Create2Factory bytecode, proxy admins,
///      live core wiring, validator timelocks, settlement layer.
///      Subsumes legacy's early chain-id sanity (legacy steps 2–3).
///   4. Deployment provenance — every named upgrade deploy (legacy step 4).
///   5. Per-chain protocol-version sweep — was bundled inside legacy
///      `deployed_addresses.verify`; sits next to provenance for the same
///      reason.
///   6. Stage 0 / 1 / 2 governance calls (legacy steps 7–9). Last.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify(
    env: VerifyUpgradeEnv,
    artifact: &EcosystemUpgradeArtifact,
    l1_rpc_url: &str,
    contracts_commit: Option<&str>,
    zk_governance_commit: &str,
    era_chain_id: u64,
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
    let mut verifiers = Verifiers::new_v33(
        env,
        artifact,
        l1_rpc_url,
        contracts_commit,
        zk_governance_commit,
        era_chain_id,
        l1_chain_id,
        zk_token_asset_id,
    )
    .await?;
    result.report_ok(&format!(
        "v33 verifier context loaded with {} named addresses",
        verifiers.address_verifier.name_to_address.len()
    ));

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

    verify_v33_artifact_state(artifact, &verifiers, create2_factory, result).await?;

    verify_v33_provenance(artifact, &verifiers, result).await?;

    verify_per_chain_protocol_versions(artifact, &verifiers, result).await?;

    verify_governance_stage_calls(artifact, &verifiers, result).await?;

    verify_ctm_admin_calls(artifact, &verifiers, result).await?;

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

    #[test]
    fn v35_target_comes_from_genesis_and_accepts_v34_patch_sources() {
        let verifiers = Verifiers::offline_v34();
        assert_eq!(
            get_expected_new_protocol_version(&verifiers),
            ProtocolVersion::from_str("0.35.0").unwrap()
        );
        assert!(is_expected_old_protocol_version_for_ctm_flavor(
            ProtocolVersion::from_str("0.34.2").unwrap(),
            CtmFlavor::ZksyncOs
        ));
        assert!(!is_expected_old_protocol_version_for_ctm_flavor(
            ProtocolVersion::from_str("0.35.0").unwrap(),
            CtmFlavor::ZksyncOs
        ));
    }
}
