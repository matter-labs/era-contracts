#![allow(dead_code, private_interfaces)]

use std::str::FromStr;

use crate::upgrade_verification::{
    artifacts::PreparedUpgradeArtifacts, verifiers::VerificationResult,
};

pub(crate) mod elements;
pub(crate) mod utils;

use elements::protocol_version::ProtocolVersion;
pub(crate) use elements::UpgradeOutput;

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
    _artifacts: &PreparedUpgradeArtifacts,
    _l1_rpc_url: &str,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== Config verification ==");

    // The next steps in this module should mirror PUVT's `UpgradeOutput::verify`:
    // decode stage calls, verify stage ordering/selectors, decode setNewVersionUpgrade,
    // and validate the embedded L2 upgrade transaction.

    Ok(())
}
