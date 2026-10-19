//! The `[member_deployments]` record every upgrade prepare writes
//! (`deploy-scripts/utils/MemberDeploymentsRecord.sol`): each contract the run deployed through
//! `deploySimpleContract` or as a proxy implementation, keyed by its address, with the CREATE2
//! factory, the salt and the exact constructor arguments it was deployed with. The verifier
//! re-derives every member a package newly installs from it (`ecosystem verify-package`).
//!
//! ```toml
//! [member_deployments.0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed]
//! contract = "AdminFacet"
//! create2_factory = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
//! create2_salt = "0x…"
//! constructor_args = "0x…"
//! ```

use std::collections::BTreeMap;

use alloy::primitives::{Address, Bytes, B256};
use serde::{Deserialize, Serialize};

/// How one contract was CREATE2-deployed.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MemberDeploymentRecord {
    /// The artifact contract name its creation code was read from.
    pub contract: String,
    pub create2_factory: Address,
    pub create2_salt: B256,
    /// Exactly the bytes appended to the creation code; empty for a constructor without arguments.
    pub constructor_args: Bytes,
}

/// The records of one or more prepare outputs, by deployed address.
pub type MemberDeployments = BTreeMap<Address, MemberDeploymentRecord>;

/// Parses one `[member_deployments]` table into its entries, in key order. A key that is not an
/// address is refused: it names no deployment the review could look up. Two keys spelling one
/// address differently both come back; merging them is the caller's.
pub fn parse_table(value: &toml::Value) -> anyhow::Result<Vec<(Address, MemberDeploymentRecord)>> {
    let raw: BTreeMap<String, MemberDeploymentRecord> = value.clone().try_into()?;
    raw.into_iter()
        .map(|(key, record)| {
            let address = key.parse::<Address>().map_err(|e| {
                anyhow::anyhow!("member deployment key {key:?} is not an address ({e})")
            })?;
            Ok((address, record))
        })
        .collect()
}
