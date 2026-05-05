#![allow(dead_code, private_interfaces)]

use std::str::FromStr;

use crate::upgrade_verification::{
    artifacts::EcosystemUpgradeArtifact,
    verifiers::{GenesisConfigKind, VerificationResult, Verifiers},
};

pub(crate) mod elements;
pub(crate) mod utils;

pub(crate) use elements::UpgradeOutput;
use elements::{
    governance_stage_calls::verify_governance_stage_calls, protocol_version::ProtocolVersion,
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

pub(crate) async fn verify(
    artifact: &EcosystemUpgradeArtifact,
    l1_rpc_url: &str,
    contracts_commit: Option<&str>,
    genesis_config_kind: GenesisConfigKind,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== Config verification ==");
    let verifiers =
        Verifiers::new_v31(artifact, l1_rpc_url, contracts_commit, genesis_config_kind).await?;
    result.report_ok(&format!(
        "v31 verifier context loaded with {} named addresses",
        verifiers.address_verifier.name_to_address.len()
    ));

    verify_governance_stage_calls(artifact, &verifiers, result)?;

    Ok(())
}
