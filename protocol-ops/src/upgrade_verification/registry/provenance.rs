//! Does the code at each address belong to the reviewed commit?
//!
//! Under the registry model this replaces v31's CREATE2-transaction archaeology. There, a
//! reviewer had to reconstruct each deployment from an append-only transaction log to learn
//! what had been deployed. Here the answer comes from the REVIEWED COMMIT's own artifacts: the
//! live code is compared against the deployed bytecode the reviewed build produces for the
//! contract its role admits, and that build is held against `AllContractsHashes.json`
//! ([`super::construction::ReviewedBuild`]). Nothing the package supplies takes part in that
//! comparison — a fingerprint the package carried would only prove the package is
//! self-consistent.
//!
//! # Constructor-set immutables
//!
//! An artifact's deployed bytecode carries ZEROED immutable slots, so a contract that sets
//! immutables in its constructor never hashes to its own artifact once deployed. The comparison
//! therefore masks exactly the artifact's `immutableReferences` and requires every other byte —
//! and the length — to match ([`super::construction::ReviewedArtifact::is_runtime_of`]). That
//! proves the account runs the reviewed CODE; the VALUES in the masked slots are the deploying
//! constructor's, and this module says nothing about them. For the objects a package names that
//! is closed by their construction ([`super::construction`]); for the members those objects name
//! it is the limit of this check (see the module docs of [`super::members`]).
//!
//! Code the build does not produce for the expected contract is an error — never a warning that
//! could accompany a successful review.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use alloy::primitives::{Address, FixedBytes, B256};
use alloy::providers::Provider;

use crate::upgrade_verification::{contract_hashes::ContractHashes, report::VerificationResult};

use super::construction::ReviewedBuild;

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

/// A ZKsync OS bytecode info's three fields (`ZKSyncOSBytecodeInfo`): the deployed bytecode's
/// blake2s hash, its length and its keccak256 ("observable") hash.
pub(crate) type BytecodeInfoKey = (B256, u32, B256);

/// The reviewed commit's contracts, indexed by deployed-bytecode hash (what is this code?), by
/// short contract name (what does the commit build for it?) and by ZKsync OS bytecode info (which
/// contract does an L2 bytecode descriptor name?).
pub(crate) struct CodeIdentity {
    /// The hashes file this index was read from.
    source: PathBuf,
    by_codehash: HashMap<FixedBytes<32>, String>,
    creation_code_by_short_name: HashMap<String, FixedBytes<32>>,
    deployed_code_by_short_name: HashMap<String, FixedBytes<32>>,
    by_bytecode_info: HashMap<BytecodeInfoKey, String>,
}

impl CodeIdentity {
    pub(crate) fn from_hashes_file(path: &Path) -> anyhow::Result<Self> {
        let hashes = ContractHashes::init_from_file(path)?;
        let mut identity = Self::empty();
        identity.source = path.to_path_buf();
        for contract in hashes.hashes {
            let short = contract
                .contract_name
                .rsplit('/')
                .next()
                .unwrap_or_default()
                .to_string();
            let parse = |hash: Option<&str>| hash.and_then(|h| h.parse::<FixedBytes<32>>().ok());
            if let Some(hash) = parse(contract.evm_bytecode_hash.as_deref()) {
                identity
                    .creation_code_by_short_name
                    .entry(short.clone())
                    .or_insert(hash);
            }
            let deployed = parse(contract.evm_deployed_bytecode_hash.as_deref());
            if let Some(hash) = deployed {
                identity
                    .deployed_code_by_short_name
                    .entry(short)
                    .or_insert(hash);
                // First writer wins: a duplicate hash means two names share bytecode
                // (identical sources), and either name is a truthful answer.
                identity
                    .by_codehash
                    .entry(hash)
                    .or_insert_with(|| contract.contract_name.clone());
            }
            if let (Some(keccak), Some(blake), Some(length)) = (
                deployed,
                parse(contract.evm_deployed_bytecode_blake_hash.as_deref()),
                contract.evm_deployed_bytecode_length,
            ) {
                identity
                    .by_bytecode_info
                    .entry((blake, length, keccak))
                    .or_insert_with(|| contract.contract_name.clone());
            }
        }
        Ok(identity)
    }

    /// An index of nothing, read from nowhere.
    pub(crate) fn empty() -> Self {
        Self {
            source: PathBuf::new(),
            by_codehash: HashMap::new(),
            creation_code_by_short_name: HashMap::new(),
            deployed_code_by_short_name: HashMap::new(),
            by_bytecode_info: HashMap::new(),
        }
    }

    /// The hashes file this index was read from.
    pub(crate) fn source(&self) -> &Path {
        &self.source
    }

    /// The reviewed-commit name for `codehash`, if the commit produces that code at all.
    pub(crate) fn name_of(&self, codehash: &FixedBytes<32>) -> Option<&str> {
        self.by_codehash.get(codehash).map(String::as_str)
    }

    /// The CREATION-code hash the reviewed commit produces for `short_name`.
    ///
    /// What a locally built artifact is held against before its bytes are used to derive an
    /// object's address: the bytes come from an uncommitted build directory, the hash from the
    /// committed record.
    pub(crate) fn creation_code_hash_of(&self, short_name: &str) -> Option<FixedBytes<32>> {
        self.creation_code_by_short_name.get(short_name).copied()
    }

    /// The DEPLOYED-bytecode hash the reviewed commit produces for `short_name` (immutable slots
    /// zeroed), which a locally built artifact is held against before live code is compared with
    /// it.
    pub(crate) fn deployed_code_hash_of(&self, short_name: &str) -> Option<FixedBytes<32>> {
        self.deployed_code_by_short_name.get(short_name).copied()
    }

    /// The reviewed-commit contract whose deployed bytecode a ZKsync OS bytecode info describes.
    pub(crate) fn name_of_bytecode_info(&self, info: &BytecodeInfoKey) -> Option<&str> {
        self.by_bytecode_info.get(info).map(String::as_str)
    }

    #[cfg(test)]
    pub(crate) fn with_contract(mut self, name: &str, deployed: &[u8]) -> Self {
        let hash = alloy::primitives::keccak256(deployed);
        self.by_codehash.insert(hash, name.to_string());
        self.deployed_code_by_short_name.insert(
            name.rsplit('/').next().unwrap_or_default().to_string(),
            hash,
        );
        self
    }

    #[cfg(test)]
    pub(crate) fn with_bytecode_info(mut self, name: &str, info: BytecodeInfoKey) -> Self {
        self.by_bytecode_info.insert(info, name.to_string());
        self
    }
}

/// What the reviewed build says about live code. Separated from the reporting so the
/// classification is testable on its own: whether unknown code counts as a finding is the whole
/// question this verifier turns on.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CodeVerdict<'a> {
    /// The code is the reviewed build of `name`, one of the expected contracts — byte for byte
    /// outside its `immutable_slots` constructor-set slots.
    Reviewed {
        name: &'static str,
        immutable_slots: usize,
    },
    /// The commit produces this code for a DIFFERENT contract, named here.
    OtherContract(&'a str),
    /// The commit produces this code for nothing the build can name: what runs there is unknown.
    Unknown,
    /// An expected contract's reviewed artifact is unavailable, so the code cannot be judged.
    Unverifiable(String),
}

/// Classifies `live` against the reviewed build of each `expected` contract.
///
/// `Unknown` is deliberately its own verdict rather than a benign default: whatever else the
/// package claims about the address, a reviewer who cannot name the deployed code has not
/// verified it.
pub(crate) fn classify_code<'a>(
    build: &'a ReviewedBuild,
    live: &[u8],
    expected: &[&'static str],
) -> CodeVerdict<'a> {
    let mut unavailable = Vec::new();
    for name in expected {
        match build.get(name) {
            Ok(artifact) if artifact.is_runtime_of(live) => {
                return CodeVerdict::Reviewed {
                    name,
                    immutable_slots: artifact.immutable_slots(),
                }
            }
            Ok(_) => {}
            Err(why) => unavailable.push(format!("{name}: {why}")),
        }
    }
    if !unavailable.is_empty() {
        return CodeVerdict::Unverifiable(unavailable.join("; "));
    }
    match build
        .identity()
        .name_of(&alloy::primitives::keccak256(live))
    {
        Some(other) => CodeVerdict::OtherContract(other),
        None => CodeVerdict::Unknown,
    }
}

/// Reports whether the account at `address` runs the code the reviewed build produces for one of
/// the `expected` contracts, and returns which. Both the objects a package names (one expected
/// contract each) and the members those objects name (every contract the member's role admits)
/// go through here.
///
/// The outcomes a reviewer must be able to tell apart are reported separately: the address has
/// no code at all; it runs code the build produces for a different contract (named); it runs code
/// the build does not produce (which is what a wrong compilation profile or a foreign contract
/// looks like); or the expected artifact could not be loaded. Each is an ERROR.
pub(crate) async fn expect_code_identity<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
    expected: &[&'static str],
) -> anyhow::Result<Option<&'static str>> {
    if address.is_zero() {
        result.report_error(&format!("{label} is the zero address"));
        return Ok(None);
    }

    let code = provider.get_code_at(address).await?;
    if code.is_empty() {
        result.report_error(&format!(
            "{label} at {address} has NO code: nothing is deployed there"
        ));
        return Ok(None);
    }

    let expectation = expected.join(" or ");
    match classify_code(build, &code, expected) {
        CodeVerdict::Reviewed {
            name,
            immutable_slots: 0,
        } => {
            result.report_ok(&format!("{label} at {address} runs the reviewed {name}"));
            Ok(Some(name))
        }
        CodeVerdict::Reviewed {
            name,
            immutable_slots,
        } => {
            result.report_ok(&format!(
                "{label} at {address} runs the reviewed {name} (byte for byte outside its \
                 {immutable_slots} constructor-set immutable slot(s))"
            ));
            Ok(Some(name))
        }
        CodeVerdict::OtherContract(other) => {
            result.report_error(&format!(
                "{label} at {address} runs {other}, not {expectation}"
            ));
            Ok(None)
        }
        CodeVerdict::Unknown => {
            // An ERROR, not a warning: the reviewer cannot say what is deployed here, and an
            // unresolved deployment must not ride along with an otherwise successful review.
            // The benign causes name themselves in the message; they are fixed BEFORE the review
            // concludes, not annotated in it.
            result.report_error(&format!(
                "{label} at {address} runs code ({}) that is not the reviewed build of \
                 {expectation}, nor any contract {} attributes: what is deployed there is \
                 unknown. Regenerate the hashes for the reviewed commit, or confirm the object \
                 was built with the reviewed compiler profile",
                alloy::primitives::keccak256(&code),
                build.identity().source().display()
            ));
            Ok(None)
        }
        CodeVerdict::Unverifiable(why) => {
            result.report_error(&format!(
                "{label} at {address}: its code cannot be held against the reviewed build of \
                 {expectation} — {why}"
            ));
            Ok(None)
        }
    }
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
    use alloy::primitives::keccak256;

    /// The one immutable slot of [`runtime_with_immutable`].
    const IMMUTABLE_SLOT: std::ops::Range<usize> = 4..36;

    /// A contract whose constructor sets one immutable: a 32-byte slot at offset 4 of its runtime.
    fn runtime_with_immutable() -> Vec<u8> {
        let mut code = b"PUSH".to_vec();
        code.extend_from_slice(&[0u8; 32]);
        code.extend_from_slice(b" the reviewed facet runtime");
        code
    }

    fn deployed_with_immutable(value: u8) -> Vec<u8> {
        let mut code = runtime_with_immutable();
        code[IMMUTABLE_SLOT].fill(value);
        code
    }

    const RELEASE_RUNTIME: &[u8] = b"the reviewed CTMRelease runtime";
    const TRANSITION_RUNTIME: &[u8] = b"the reviewed ProxyUpgradeTransition runtime";

    fn build() -> ReviewedBuild {
        let identity = CodeIdentity::empty()
            .with_contract("l1-contracts/CTMRelease", RELEASE_RUNTIME)
            .with_contract("l1-contracts/ProxyUpgradeTransition", TRANSITION_RUNTIME)
            .with_contract("l1-contracts/MailboxFacet", &runtime_with_immutable());
        ReviewedBuild::from_artifacts(
            identity,
            vec![
                (
                    "CTMRelease.sol",
                    "CTMRelease",
                    Vec::new(),
                    RELEASE_RUNTIME.to_vec(),
                    Vec::new(),
                ),
                (
                    "Mailbox.sol",
                    "MailboxFacet",
                    Vec::new(),
                    runtime_with_immutable(),
                    vec![IMMUTABLE_SLOT],
                ),
            ],
        )
    }

    #[test]
    fn the_reviewed_runtime_is_recognized() {
        assert_eq!(
            classify_code(&build(), RELEASE_RUNTIME, &["CTMRelease"]),
            CodeVerdict::Reviewed {
                name: "CTMRelease",
                immutable_slots: 0
            }
        );
    }

    /// The immutable slot carries whatever the deploying constructor wrote, so it is masked: the
    /// same code with any value there is the reviewed contract.
    #[test]
    fn immutable_slots_are_masked() {
        for value in [0x00, 0x11, 0xff] {
            assert_eq!(
                classify_code(&build(), &deployed_with_immutable(value), &["MailboxFacet"]),
                CodeVerdict::Reviewed {
                    name: "MailboxFacet",
                    immutable_slots: 1
                }
            );
        }
    }

    /// Masking is exactly the artifact's immutable ranges: one byte changed anywhere else, or one
    /// byte more, is not the reviewed contract.
    #[test]
    fn a_byte_outside_the_immutable_slots_is_not_masked() {
        let mut tampered = deployed_with_immutable(0x11);
        tampered[40] ^= 0x01;
        assert_eq!(
            classify_code(&build(), &tampered, &["MailboxFacet"]),
            CodeVerdict::Unknown
        );
        let mut longer = deployed_with_immutable(0x11);
        longer.push(0x00);
        assert_eq!(
            classify_code(&build(), &longer, &["MailboxFacet"]),
            CodeVerdict::Unknown
        );
    }

    /// The match is the first of the role's admitted contracts the code IS.
    #[test]
    fn a_member_matches_any_contract_its_role_admits() {
        assert_eq!(
            classify_code(
                &build(),
                &deployed_with_immutable(0x22),
                &["CTMRelease", "MailboxFacet"]
            ),
            CodeVerdict::Reviewed {
                name: "MailboxFacet",
                immutable_slots: 1
            }
        );
    }

    #[test]
    fn code_the_commit_produces_for_another_contract_names_it() {
        assert_eq!(
            classify_code(&build(), TRANSITION_RUNTIME, &["CTMRelease"]),
            CodeVerdict::OtherContract("l1-contracts/ProxyUpgradeTransition")
        );
    }

    /// The regression this verifier exists for: a deployment the reviewed commit does not
    /// produce is UNKNOWN and therefore a finding — whatever fingerprint a package might have
    /// carried for it. A self-supplied hash of exactly this code would have "matched" and
    /// reported success.
    #[test]
    fn unrecognized_code_is_a_verdict_of_its_own() {
        assert_eq!(
            classify_code(&build(), b"code no reviewed artifact is", &["CTMRelease"]),
            CodeVerdict::Unknown
        );
    }

    /// An expected contract whose artifact the build could not load cannot pass silently.
    #[test]
    fn an_unloadable_expected_artifact_is_unverifiable() {
        assert!(matches!(
            classify_code(&build(), RELEASE_RUNTIME, &["DiamondInit"]),
            CodeVerdict::Unverifiable(_)
        ));
    }

    #[test]
    fn resolves_a_codehash_to_its_path_qualified_name() {
        let id = CodeIdentity::empty().with_contract("l1-contracts/CTMRelease", RELEASE_RUNTIME);
        assert_eq!(
            id.name_of(&keccak256(RELEASE_RUNTIME)),
            Some("l1-contracts/CTMRelease")
        );
        assert!(id.name_of(&keccak256(b"other")).is_none());
    }

    /// The hashes file indexes every hash a row carries: creation code, deployed bytecode and the
    /// ZKsync OS bytecode info triple. A duplicate codehash keeps the first name — two names can
    /// legitimately share bytecode when their sources are identical.
    #[test]
    fn a_hashes_file_is_indexed_by_every_hash_it_records() {
        let hash = |byte: u8| format!("{}", B256::repeat_byte(byte));
        let row = |name: &str| ContractHash {
            contract_name: name.into(),
            evm_bytecode_hash: Some(hash(0x01)),
            evm_deployed_bytecode_hash: Some(hash(0x02)),
            evm_deployed_bytecode_blake_hash: Some(hash(0x03)),
            evm_deployed_bytecode_length: Some(7),
            zk_bytecode_hash: None,
        };
        let dir = std::env::temp_dir().join(format!(
            "protocol-ops-provenance-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hashes.json");
        std::fs::write(
            &path,
            serde_json::to_string(&[row("l1-contracts/First"), row("l1-contracts/Second")])
                .unwrap(),
        )
        .unwrap();
        let id = CodeIdentity::from_hashes_file(&path).unwrap();
        assert_eq!(id.source(), path.as_path());
        assert_eq!(
            id.creation_code_hash_of("First"),
            Some(B256::repeat_byte(0x01))
        );
        assert_eq!(
            id.deployed_code_hash_of("Second"),
            Some(B256::repeat_byte(0x02))
        );
        assert_eq!(
            id.name_of(&B256::repeat_byte(0x02)),
            Some("l1-contracts/First")
        );
        assert_eq!(
            id.name_of_bytecode_info(&(B256::repeat_byte(0x03), 7, B256::repeat_byte(0x02))),
            Some("l1-contracts/First")
        );
        assert!(id
            .name_of_bytecode_info(&(B256::repeat_byte(0x03), 8, B256::repeat_byte(0x02)))
            .is_none());
    }

    // ───────────────────────── the reporting path ─────────────────────────
    //
    // The classifier decides nothing on its own; what fails a run is the report. These drive
    // `expect_code_identity` over a mocked transport (one queued `eth_getCode` answer), so the
    // property the module turns on — unattributed code FAILS the run rather than passing as an
    // unresolved deployment — is held on the code that reports, not only on the verdict.

    fn mocked_provider(code: &[u8]) -> impl Provider {
        use alloy::providers::ProviderBuilder;
        use alloy::transports::mock::Asserter;
        let asserter = Asserter::new();
        asserter.push_success(&alloy::primitives::Bytes::copy_from_slice(code));
        ProviderBuilder::new().connect_mocked_client(asserter)
    }

    async fn report(
        code: &[u8],
        expected: &[&'static str],
    ) -> (Option<&'static str>, VerificationResult) {
        let provider = mocked_provider(code);
        let mut result = VerificationResult::default();
        let verdict = expect_code_identity(
            &provider,
            &build(),
            &mut result,
            "the member",
            Address::repeat_byte(0x11),
            expected,
        )
        .await
        .expect("a mocked read is not a transport failure");
        (verdict, result)
    }

    #[tokio::test]
    async fn code_the_commit_does_not_produce_fails_the_run() {
        let (verdict, result) = report(b"code no reviewed artifact is", &["CTMRelease"]).await;
        assert_eq!(verdict, None);
        assert_eq!(
            result.errors, 1,
            "unknown code must be an error, never a warning"
        );
        assert_eq!(result.warnings, 0);
        assert!(result.ensure_success().is_err());
    }

    #[tokio::test]
    async fn code_the_commit_produces_for_the_expected_contract_passes() {
        let (verdict, result) = report(RELEASE_RUNTIME, &["CTMRelease"]).await;
        assert_eq!(verdict, Some("CTMRelease"));
        assert_eq!(result.errors, 0);
    }

    #[tokio::test]
    async fn a_member_with_its_immutables_set_passes_and_another_contract_fails() {
        let (verdict, result) = report(&deployed_with_immutable(0x42), &["MailboxFacet"]).await;
        assert_eq!(verdict, Some("MailboxFacet"));
        assert_eq!(result.errors, 0);

        let (verdict, result) = report(TRANSITION_RUNTIME, &["MailboxFacet"]).await;
        assert_eq!(verdict, None);
        assert_eq!(result.errors, 1);
    }

    #[tokio::test]
    async fn no_code_and_the_zero_address_fail_the_run() {
        let (verdict, result) = report(&[], &["CTMRelease"]).await;
        assert_eq!(verdict, None);
        assert_eq!(result.errors, 1);

        let mut result = VerificationResult::default();
        let provider = mocked_provider(RELEASE_RUNTIME);
        assert_eq!(
            expect_code_identity(
                &provider,
                &build(),
                &mut result,
                "the member",
                Address::ZERO,
                &["CTMRelease"],
            )
            .await
            .unwrap(),
            None
        );
        assert_eq!(result.errors, 1);
    }

    #[tokio::test]
    async fn an_unverifiable_member_fails_the_run() {
        let (verdict, result) = report(RELEASE_RUNTIME, &["DiamondInit"]).await;
        assert_eq!(verdict, None);
        assert_eq!(result.errors, 1);
    }
}
