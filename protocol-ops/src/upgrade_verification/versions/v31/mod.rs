// TODO: drop once the scaffolding kept for R2 (fee-params) and S2d
// (`check_gw_create2_deploy`) is resolved.
#![allow(dead_code, private_interfaces)]

use std::str::FromStr;

use alloy::primitives::{Address, FixedBytes, U256};

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
    deployed_addresses::verify_v31_provenance,
    governance_stage_calls::{verify_governance_stage_calls, verify_per_chain_protocol_versions},
    protocol_version::ProtocolVersion,
    rpc_state::verify_v31_artifact_state,
};

pub(crate) const EXPECTED_NEW_PROTOCOL_VERSION_STR: &str = "0.31.0";
pub(crate) const EXPECTED_ERA_OLD_PROTOCOL_VERSION_STR: &str = "0.29.4";
pub(crate) const EXPECTED_ZKSYNC_OS_OLD_PROTOCOL_VERSION_STR: &str = "0.30.1";
pub(crate) const MAX_NUMBER_OF_ZK_CHAINS: u32 = 100;
pub(crate) const MAX_PRIORITY_TX_GAS_LIMIT: u32 = 72_000_000;

/// Stage Sepolia's Era chain (270) is the single registered chain still
/// settling on the legacy stage Gateway at v31 upgrade time.
/// `L1MessageRootStageSepolia._v31InitializeInner` skips it (see
/// `l1-contracts/contracts/dev-contracts/L1MessageRootStageSepolia.sol`),
/// so PUVT must apply the same skip when pre-flighting the
/// `Bridgehub.settlementLayer(chainId) == L1` invariant on stage.
pub(crate) const STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID: u64 = 270;

pub(crate) fn get_expected_new_protocol_version() -> ProtocolVersion {
    ProtocolVersion::from_str(EXPECTED_NEW_PROTOCOL_VERSION_STR).unwrap()
}

pub(crate) fn get_expected_old_protocol_version_for_ctm_flavor(
    flavor: CtmFlavor,
) -> ProtocolVersion {
    let version = match flavor {
        CtmFlavor::Era => EXPECTED_ERA_OLD_PROTOCOL_VERSION_STR,
        CtmFlavor::ZksyncOs => EXPECTED_ZKSYNC_OS_OLD_PROTOCOL_VERSION_STR,
    };
    ProtocolVersion::from_str(version).unwrap()
}

pub(crate) fn is_expected_old_protocol_version_for_ctm_flavor(
    version: ProtocolVersion,
    flavor: CtmFlavor,
) -> bool {
    version == get_expected_old_protocol_version_for_ctm_flavor(flavor)
}

pub(crate) fn expected_old_protocol_version_label(flavor: CtmFlavor) -> &'static str {
    match flavor {
        CtmFlavor::Era => "v0.29.4",
        CtmFlavor::ZksyncOs => "v0.30.1",
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify(
    env: VerifyUpgradeEnv,
    artifact: &EcosystemUpgradeArtifact,
    l1_rpc_url: &str,
    gw_rpc_url: &str,
    contracts_commit: Option<&str>,
    era_chain_id: u64,
    legacy_gateway_chain_id: u64,
    new_gateway_chain_id: u64,
    new_gateway_representative_chain_id: u64,
    new_gateway_settlement_fee: U256,
    l1_chain_id: u64,
    tx_hashes: &[FixedBytes<32>],
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
        gw_rpc_url,
        contracts_commit,
        era_chain_id,
        legacy_gateway_chain_id,
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
    result.report_ok(&format!(
        "Gateway RPC chain ID: {}",
        verifiers.network_verifier.get_gateway_chain_id()
    ));

    // Populate the create2 maps so deployment provenance can match
    // deployed addresses against expected init bytecode + constructor args.
    // Each tx is fetched from L1 RPC; stale entries (whose bytecode no longer
    // matches AllContractsHashes after a regen) are silently skipped — the
    // address-book lookup in `expect_create2_params` hard-errors only if a
    // load-bearing deployment is missing.
    let count = {
        let Verifiers {
            bytecode_verifier,
            network_verifier,
            ..
        } = &mut verifiers;
        network_verifier
            .populate_create2_from_transactions_log(
                tx_hashes,
                &create2_factory,
                expected_salts,
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

    verify_governance_stage_calls(artifact, &verifiers, result).await?;

    verify_per_chain_protocol_versions(artifact, &verifiers, result).await?;

    verify_v31_artifact_state(artifact, &verifiers, create2_factory, result).await?;

    verify_v31_provenance(
        artifact,
        &verifiers,
        era_chain_id,
        legacy_gateway_chain_id,
        result,
    )
    .await?;

    Ok(())
}
