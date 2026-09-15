//! Does the code at each address belong to the reviewed commit?
//!
//! Under the registry model this replaces v31's CREATE2-transaction archaeology. There, a
//! reviewer had to reconstruct each deployment from an append-only transaction log to learn
//! what had been deployed. Here the answer comes from the REVIEWED COMMIT's own artifacts:
//! live `EXTCODEHASH` against `AllContractsHashes.json`. Nothing the package supplies takes
//! part in that comparison — a fingerprint the package carried would only prove the package
//! is self-consistent.
//!
//! # Constructor-set immutables
//!
//! `AllContractsHashes.json` records the ARTIFACT's deployed bytecode, whose immutable slots
//! are zero. A contract that sets immutables in its constructor therefore never hashes to its
//! own artifact once deployed, and a hash lookup for it misses by construction. Such a contract
//! is not waved through: [`expect_immutable_bearing_identity`] requires every immutable the
//! reviewer depends on to be read back from the deployment and to equal the reviewed value, and
//! a mismatch is an error like any other. Objects WITHOUT immutables go through
//! [`expect_code_identity`], where code the commit does not produce is an error — never a
//! warning that could accompany a successful review.

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

/// The reviewed commit's contracts, indexed both ways: by deployed-bytecode hash (what is this
/// code?) and by short contract name (what should this contract's code hash to?).
pub(crate) struct CodeIdentity {
    by_codehash: HashMap<FixedBytes<32>, String>,
    by_short_name: HashMap<String, FixedBytes<32>>,
}

impl CodeIdentity {
    pub(crate) fn from_local_hashes() -> anyhow::Result<Self> {
        let hashes = ContractHashes::init_from_local()?;
        let mut by_codehash = HashMap::new();
        let mut by_short_name = HashMap::new();
        for contract in hashes.hashes {
            if let Some(hash) = contract.evm_deployed_bytecode_hash.as_deref() {
                if let Ok(parsed) = hash.parse::<FixedBytes<32>>() {
                    // First writer wins: a duplicate hash means two names share bytecode
                    // (identical sources), and either name is a truthful answer.
                    by_codehash
                        .entry(parsed)
                        .or_insert_with(|| contract.contract_name.clone());
                    if let Some(short) = contract.contract_name.rsplit('/').next() {
                        by_short_name.entry(short.to_string()).or_insert(parsed);
                    }
                }
            }
        }
        Ok(Self {
            by_codehash,
            by_short_name,
        })
    }

    /// The reviewed-commit name for `codehash`, if the commit produces that code at all.
    pub(crate) fn name_of(&self, codehash: &FixedBytes<32>) -> Option<&str> {
        self.by_codehash.get(codehash).map(String::as_str)
    }

    /// The deployed-bytecode hash the reviewed commit produces for `short_name`.
    ///
    /// Meaningful only for contracts with no constructor-set immutables — which is exactly what
    /// the object-type anchors cover (`CTMTransition`, `CoreRegistry`,
    /// `EcosystemUpgradeOperation`), so an executor's anchor immutable can be checked against
    /// the commit rather than against whatever the package says it should be.
    pub(crate) fn codehash_of(&self, short_name: &str) -> Option<FixedBytes<32>> {
        self.by_short_name.get(short_name).copied()
    }
}

/// One constructor-set immutable, as read back from the deployment and as the review expects it.
pub(crate) struct ImmutableValue {
    pub(crate) name: &'static str,
    pub(crate) actual: String,
    pub(crate) expected: String,
}

impl ImmutableValue {
    pub(crate) fn new(
        name: &'static str,
        actual: impl std::fmt::Display,
        expected: impl std::fmt::Display,
    ) -> Self {
        Self {
            name,
            actual: actual.to_string(),
            expected: expected.to_string(),
        }
    }

    fn holds(&self) -> bool {
        self.actual.eq_ignore_ascii_case(&self.expected)
    }
}

/// What the reviewed commit says about a live codehash. Separated from the reporting so the
/// classification is testable on its own: whether unknown code counts as a finding is the whole
/// question this verifier turns on.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CodeVerdict<'a> {
    /// The commit produces this code for the expected contract.
    Reviewed(&'a str),
    /// The commit produces this code for a DIFFERENT contract, named here.
    OtherContract(&'a str),
    /// The commit produces this code for nothing at all: what runs there is unknown.
    Unknown,
}

/// Classifies `live` against the reviewed commit.
///
/// `Unknown` is deliberately its own verdict rather than a benign default: whatever else the
/// package claims about the address, a reviewer who cannot name the deployed code has not
/// verified it.
pub(crate) fn classify_code<'a>(
    identity: &'a CodeIdentity,
    live: &FixedBytes<32>,
    expected_short_name: &str,
) -> CodeVerdict<'a> {
    match identity.name_of(live) {
        Some(name) if name.rsplit('/').next() == Some(expected_short_name) => {
            CodeVerdict::Reviewed(name)
        }
        Some(other) => CodeVerdict::OtherContract(other),
        None => CodeVerdict::Unknown,
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
    match classify_code(identity, &live, expected_short_name) {
        CodeVerdict::Reviewed(name) => {
            result.report_ok(&format!("{label} at {address} runs {name}"));
            Ok(true)
        }
        CodeVerdict::OtherContract(other) => {
            result.report_error(&format!(
                "{label} at {address} runs {other}, not {expected_short_name}"
            ));
            Ok(false)
        }
        CodeVerdict::Unknown => {
            // An ERROR, not a warning: the reviewer cannot say what is deployed here, and an
            // unresolved deployment must not ride along with an otherwise successful review.
            // The two benign causes name themselves in the message; both are fixed BEFORE the
            // review concludes, not annotated in it.
            result.report_error(&format!(
                "{label} at {address} runs code ({live}) that AllContractsHashes.json does not \
                 attribute to any contract: what is deployed there is unknown. Regenerate \
                 AllContractsHashes.json for the reviewed commit, or confirm the object was \
                 built with the deterministic (metadata-free) profile"
            ));
            Ok(false)
        }
    }
}

/// Reports whether the account at `address` is the reviewed `expected_short_name` deployment,
/// for a contract that sets IMMUTABLES in its constructor.
///
/// Such a deployment cannot hash to its own artifact (the artifact's immutable slots are zero),
/// so identity is established from the immutable VALUES the reviewer depends on: each is read
/// back from the deployment and compared with the reviewed value, and any mismatch is an error.
/// A live hash that resolves to a DIFFERENT reviewed contract is still an error — that is a
/// definitive answer, whatever the immutables say.
pub(crate) async fn expect_immutable_bearing_identity<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
    expected_short_name: &str,
    immutables: &[ImmutableValue],
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
    if let CodeVerdict::OtherContract(other) = classify_code(identity, &live, expected_short_name) {
        result.report_error(&format!(
            "{label} at {address} runs {other}, not {expected_short_name}"
        ));
        return Ok(false);
    }

    let mut holds = true;
    for immutable in immutables {
        if immutable.holds() {
            result.report_ok(&format!(
                "{label}: immutable {} is {}",
                immutable.name, immutable.actual
            ));
        } else {
            holds = false;
            result.report_error(&format!(
                "{label}: immutable {} is {} but the review expects {}",
                immutable.name, immutable.actual, immutable.expected
            ));
        }
    }
    if !holds {
        return Ok(false);
    }
    result.report_ok(&format!(
        "{label} at {address} is a {expected_short_name} whose {} constructor-set immutable(s) \
         match the review; its runtime code differs from the artifact only where those values \
         are patched in",
        immutables.len()
    ));
    Ok(true)
}

/// Reports whether an address is a deployed contract at all — the precondition every object
/// this package names has to meet, and the one the objects' own `validate()` enforces on-chain.
pub(crate) async fn expect_code_present<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
) -> anyhow::Result<bool> {
    if address.is_zero() {
        result.report_error(&format!("{label} is the zero address"));
        return Ok(false);
    }
    let code = provider.get_code_at(address).await?;
    if code.is_empty() {
        result.report_error(&format!(
            "{label} at {address} has NO code: the object names an address nothing is deployed \
             to, and `validate()` refuses it on-chain"
        ));
        return Ok(false);
    }
    result.report_ok(&format!("{label} at {address} is deployed code"));
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::contract_hashes::ContractHash;

    fn identity_from(pairs: &[(&str, &str)]) -> CodeIdentity {
        let mut by_codehash = HashMap::new();
        let mut by_short_name = HashMap::new();
        for (name, hash) in pairs {
            let parsed: FixedBytes<32> = hash.parse().unwrap();
            by_codehash.insert(parsed, (*name).to_string());
            by_short_name.insert(name.rsplit('/').next().unwrap().to_string(), parsed);
        }
        CodeIdentity {
            by_codehash,
            by_short_name,
        }
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
        let id = CodeIdentity {
            by_codehash,
            by_short_name: HashMap::new(),
        };
        assert_eq!(
            id.name_of(&HASH_A.parse().unwrap()),
            Some("l1-contracts/First")
        );
    }

    /// The anchor checks resolve a SHORT name to the reviewed commit's codehash, so an
    /// executor's `TRANSITION_CODEHASH` can be held against the commit instead of against a
    /// value the package supplied.
    #[test]
    fn resolves_a_short_name_to_its_codehash() {
        let id = identity_from(&[("l1-contracts/CTMTransition", HASH_A)]);
        assert_eq!(
            id.codehash_of("CTMTransition"),
            Some(HASH_A.parse().unwrap())
        );
        assert_eq!(id.codehash_of("CoreRegistry"), None);
    }

    /// An immutable is compared case-insensitively, because the two sides are rendered from
    /// different alloy types (a checksummed `Address` against a lowercase hash string).
    #[test]
    fn immutable_values_compare_case_insensitively() {
        assert!(ImmutableValue::new("X", "0xAbCd", "0xabcd").holds());
        assert!(!ImmutableValue::new("X", "0xAbCd", "0xabce").holds());
    }

    /// The regression this verifier exists for: a deployment the reviewed commit does not
    /// produce is UNKNOWN and therefore a finding — whatever fingerprint a package might have
    /// carried for it. Under the removed pin model a self-supplied hash of exactly this code
    /// would have "matched" and reported success.
    #[test]
    fn unrecognized_code_is_a_verdict_of_its_own() {
        let id = identity_from(&[("l1-contracts/CTMRelease", HASH_A)]);
        assert_eq!(
            classify_code(&id, &HASH_B.parse().unwrap(), "CTMRelease"),
            CodeVerdict::Unknown
        );
    }

    #[test]
    fn code_the_commit_produces_for_another_contract_names_it() {
        let id = identity_from(&[("l1-contracts/CoreRegistry", HASH_A)]);
        assert_eq!(
            classify_code(&id, &HASH_A.parse().unwrap(), "CTMRelease"),
            CodeVerdict::OtherContract("l1-contracts/CoreRegistry")
        );
    }

    /// The short name is matched against the LAST path segment, so a reviewed name and the
    /// verifier's expectation agree without the verifier repeating the path.
    #[test]
    fn the_expected_contract_resolves_through_its_short_name() {
        let id = identity_from(&[("l1-contracts/CTMRelease", HASH_A)]);
        assert_eq!(
            classify_code(&id, &HASH_A.parse().unwrap(), "CTMRelease"),
            CodeVerdict::Reviewed("l1-contracts/CTMRelease")
        );
    }
}
