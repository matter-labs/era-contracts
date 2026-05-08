#![allow(dead_code, private_interfaces)]

use std::str::FromStr;

use alloy::primitives::{Address, FixedBytes};

use crate::{
    commands::dev::execute_safe::ExecutedBundle,
    upgrade_verification::{
        artifacts::EcosystemUpgradeArtifact,
        verifiers::{GenesisConfigKind, VerificationResult, Verifiers},
    },
};

pub(crate) mod elements;
pub(crate) mod utils;

pub(crate) use elements::UpgradeOutput;
use elements::{
    deployed_addresses::{verify_v31_artifact_state, verify_v31_provenance},
    governance_stage_calls::verify_governance_stage_calls,
    protocol_version::ProtocolVersion,
};

pub(crate) const EXPECTED_NEW_PROTOCOL_VERSION_STR: &str = "0.31.0";
// v31 supports chains upgrading from v29 or v30; this is only for copied PUVT scaffolding
// until old-version checks are adapted to read the prepared artifact/on-chain state.
pub(crate) const EXPECTED_OLD_PROTOCOL_VERSION_STR: &str = "0.30.0";
pub(crate) const MAX_NUMBER_OF_ZK_CHAINS: u32 = 100;
pub(crate) const MAX_PRIORITY_TX_GAS_LIMIT: u32 = 72_000_000;

pub(crate) fn get_expected_new_protocol_version() -> ProtocolVersion {
    ProtocolVersion::from_str(EXPECTED_NEW_PROTOCOL_VERSION_STR).unwrap()
}

pub(crate) fn get_expected_old_protocol_version() -> ProtocolVersion {
    ProtocolVersion::from_str(EXPECTED_OLD_PROTOCOL_VERSION_STR).unwrap()
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify(
    artifact: &EcosystemUpgradeArtifact,
    l1_rpc_url: &str,
    contracts_commit: Option<&str>,
    era_chain_id: Option<u64>,
    genesis_config_kind: GenesisConfigKind,
    executed_bundle: &ExecutedBundle,
    create2_factory: Address,
    create2_salt: FixedBytes<32>,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== Config verification ==");
    let mut verifiers = Verifiers::new_v31(
        artifact,
        l1_rpc_url,
        contracts_commit,
        era_chain_id,
        genesis_config_kind,
    )
    .await?;
    result.report_ok(&format!(
        "v31 verifier context loaded with {} named addresses",
        verifiers.address_verifier.name_to_address.len()
    ));

    // Populate the create2 maps so Phase 6 (deployment provenance) can match
    // deployed addresses against expected init bytecode + constructor args.
    let count = {
        let Verifiers {
            bytecode_verifier,
            network_verifier,
            ..
        } = &mut verifiers;
        network_verifier.populate_create2_from_executed_bundle(
            executed_bundle,
            &create2_factory,
            &create2_salt,
            bytecode_verifier,
        );
        network_verifier.create2_known_bytecodes.len()
    };
    result.report_ok(&format!(
        "Loaded {} CREATE2 deployments from executed bundle",
        count,
    ));

    verify_governance_stage_calls(artifact, &verifiers, result).await?;

    verify_v31_artifact_state(artifact, &verifiers, result).await?;

    verify_v31_provenance(
        artifact,
        &verifiers,
        era_chain_id,
        genesis_config_kind,
        result,
    )
    .await?;

    Ok(())
}
