//! Does the code at each address belong to the reviewed commit?
//!
//! Under the registry model this replaces v31's CREATE2-transaction archaeology. There, a
//! reviewer had to reconstruct each deployment from an append-only transaction log to learn
//! what had been deployed. Here every object's identity is a runtime codehash that the
//! executors and the CTM enforce on-chain, so provenance is a comparison between live
//! `EXTCODEHASH` and `AllContractsHashes.json` — no transaction history required.

use std::collections::HashMap;

use alloy::primitives::{Address, FixedBytes};
use alloy::providers::Provider;

use crate::upgrade_verification::{contract_hashes::ContractHashes, verifiers::VerificationResult};

/// Resolves an eth_call that may revert into a reported error rather than an abort.
///
/// A verification run must survive one unreadable contract: the reviewer needs every other
/// finding, and "this getter reverted" is itself a finding. Only transport failures (a dead
/// RPC) should stop the run, and those surface as `Err` from the caller's own provider use.
pub(crate) fn tolerate<T>(
    outcome: Result<T, impl std::fmt::Display>,
    result: &mut VerificationResult,
    what: &str,
) -> Option<T> {
    match outcome {
        Ok(value) => Some(value),
        Err(e) => {
            result.report_error(&format!(
                "{what} could not be read ({e}): the contract is not what this package assumes"
            ));
            None
        }
    }
}

/// Reverse map from a contract's deployed-bytecode hash to its `AllContractsHashes.json` name.
pub(crate) struct CodeIdentity {
    by_codehash: HashMap<FixedBytes<32>, String>,
}

impl CodeIdentity {
    pub(crate) fn from_local_hashes() -> anyhow::Result<Self> {
        let hashes = ContractHashes::init_from_local()?;
        let mut by_codehash = HashMap::new();
        for contract in hashes.hashes {
            if let Some(hash) = contract.evm_deployed_bytecode_hash.as_deref() {
                if let Ok(parsed) = hash.parse::<FixedBytes<32>>() {
                    // First writer wins: a duplicate hash means two names share bytecode
                    // (identical sources), and either name is a truthful answer.
                    by_codehash
                        .entry(parsed)
                        .or_insert_with(|| contract.contract_name.clone());
                }
            }
        }
        Ok(Self { by_codehash })
    }

    /// The reviewed-commit name for `codehash`, if the commit produces that code at all.
    pub(crate) fn name_of(&self, codehash: &FixedBytes<32>) -> Option<&str> {
        self.by_codehash.get(codehash).map(String::as_str)
    }
}

/// Reports whether the account at `address` runs the code the reviewed commit produces for
/// `expected_short_name`.
///
/// Three outcomes a reviewer must be able to tell apart, so they are reported separately:
/// the address has no code at all; it has code the commit does not produce (which is what a
/// wrong compilation profile or a foreign contract looks like); or it runs a DIFFERENT
/// contract from the commit, which is named in the error.
pub(crate) async fn expect_code_identity<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
    expected_short_name: &str,
) -> anyhow::Result<bool> {
    if address.is_zero() {
        result.report_error(&format!("{label} is the zero address"));
        return Ok(false);
    }

    let code = provider.get_code_at(address).await?;
    if code.is_empty() {
        result.report_error(&format!(
            "{label} at {address} has NO code: nothing is deployed there"
        ));
        return Ok(false);
    }

    let live = alloy::primitives::keccak256(&code);
    match identity.name_of(&live) {
        Some(name) if name.rsplit('/').next() == Some(expected_short_name) => {
            result.report_ok(&format!("{label} at {address} runs {name}"));
            Ok(true)
        }
        Some(other) => {
            result.report_error(&format!(
                "{label} at {address} runs {other}, not {expected_short_name}"
            ));
            Ok(false)
        }
        None => {
            // Reported as a WARNING, not an error: the overwhelmingly common cause is an
            // AllContractsHashes.json that has not been regenerated for the reviewed commit,
            // which makes every lookup miss at once. A genuinely foreign contract shows up as
            // the `Some(other)` arm above, which IS an error. `unresolved_codehashes` lets the
            // caller escalate when only SOME objects miss.
            result.report_warn(&format!(
                "{label} at {address} runs code ({live}) that AllContractsHashes.json does not \
                 attribute to any contract — regenerate it for the reviewed commit, or confirm \
                 the object was built with the deterministic (metadata-free) profile"
            ));
            Ok(false)
        }
    }
}

/// Reports whether a manifest's inline `PinnedContract` pin holds against live code.
///
/// A pin that does not hold is not a review nit: the executors and the CTM reject an object
/// whose code disagrees with its pin, so a package shipping a stale pin cannot execute.
pub(crate) async fn expect_pin_holds<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
    pinned_codehash: FixedBytes<32>,
) -> anyhow::Result<bool> {
    if address.is_zero() {
        result.report_error(&format!("{label} pins the zero address"));
        return Ok(false);
    }
    let code = provider.get_code_at(address).await?;
    if code.is_empty() {
        result.report_error(&format!(
            "{label} pins {address}, which has no code: the pin can never hold"
        ));
        return Ok(false);
    }
    let live = alloy::primitives::keccak256(&code);
    if live == pinned_codehash {
        result.report_ok(&format!("{label} pin holds against the code at {address}"));
        Ok(true)
    } else {
        result.report_error(&format!(
            "{label} pins codehash {pinned_codehash} but {address} runs {live}: execution will \
             be rejected on-chain"
        ));
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::contract_hashes::ContractHash;

    fn identity_from(pairs: &[(&str, &str)]) -> CodeIdentity {
        let mut by_codehash = HashMap::new();
        for (name, hash) in pairs {
            by_codehash.insert(hash.parse().unwrap(), (*name).to_string());
        }
        CodeIdentity { by_codehash }
    }

    const HASH_A: &str = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const HASH_B: &str = "0x2222222222222222222222222222222222222222222222222222222222222222";

    #[test]
    fn resolves_a_codehash_to_its_path_qualified_name() {
        let id = identity_from(&[("l1-contracts/CTMRelease", HASH_A)]);
        assert_eq!(
            id.name_of(&HASH_A.parse().unwrap()),
            Some("l1-contracts/CTMRelease")
        );
    }

    #[test]
    fn unknown_code_resolves_to_nothing() {
        let id = identity_from(&[("l1-contracts/CTMRelease", HASH_A)]);
        assert!(id.name_of(&HASH_B.parse().unwrap()).is_none());
    }

    /// A duplicate codehash must not panic or lose the map: two names can legitimately share
    /// bytecode when their sources are identical.
    #[test]
    fn duplicate_codehashes_keep_the_first_name() {
        let hashes = ContractHashes {
            hashes: vec![
                ContractHash {
                    contract_name: "l1-contracts/First".into(),
                    evm_bytecode_hash: None,
                    evm_deployed_bytecode_hash: Some(HASH_A.into()),
                    evm_deployed_bytecode_blake_hash: None,
                    evm_deployed_bytecode_length: None,
                    zk_bytecode_hash: None,
                },
                ContractHash {
                    contract_name: "l1-contracts/Second".into(),
                    evm_bytecode_hash: None,
                    evm_deployed_bytecode_hash: Some(HASH_A.into()),
                    evm_deployed_bytecode_blake_hash: None,
                    evm_deployed_bytecode_length: None,
                    zk_bytecode_hash: None,
                },
            ],
        };
        let mut by_codehash = HashMap::new();
        for contract in hashes.hashes {
            if let Some(h) = contract.evm_deployed_bytecode_hash.as_deref() {
                by_codehash
                    .entry(h.parse::<FixedBytes<32>>().unwrap())
                    .or_insert_with(|| contract.contract_name.clone());
            }
        }
        let id = CodeIdentity { by_codehash };
        assert_eq!(
            id.name_of(&HASH_A.parse().unwrap()),
            Some("l1-contracts/First")
        );
    }
}
