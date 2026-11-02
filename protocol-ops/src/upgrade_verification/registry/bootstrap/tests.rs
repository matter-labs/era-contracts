use super::*;
use crate::upgrade_verification::registry::views::ProxyUpgradeRow;
use alloy::primitives::{Bytes, U256};

/// The address derivation feeds `abi_encode()` in as the object's CONSTRUCTOR ARGUMENTS, so
/// it must be Solidity's `abi.encode(manifest)` — for a dynamic struct, a 0x20 offset word
/// followed by the body. `abi_encode_params` (the function-argument spelling, which omits
/// that word) would derive a different address for every object, and the failure would look
/// like a counterfeit finding, so the assumption is pinned here rather than inferred from a
/// passing run.
#[test]
fn a_manifest_encodes_as_solidity_abi_encode() {
    let manifest = views::BootstrapManifest {
        ctm: Address::repeat_byte(0x11),
        expectedProtocolVersion: U256::from(1),
        ctmProxyAdmin: Address::repeat_byte(0x22),
        ctmProxyUpgrades: Vec::new(),
        currentRelease: Address::repeat_byte(0x33),
        oldProtocolVersionDeadline: U256::from(3),
        upgradeEngine: Address::repeat_byte(0x44),
        l2Plan: views::AuthoredL2Plan {
            delegateBytecodeInfo: Default::default(),
            extraBytecodeInfos: Vec::new(),
            delegateComposer: Address::ZERO,
        },
        upgradeTimestamp: U256::from(0),
        ctmExecutor: Address::repeat_byte(0x55),
        coreExecutor: Address::repeat_byte(0x67),
        governance: Address::repeat_byte(0x66),
    };
    let encoded = manifest.abi_encode();
    assert_eq!(
        U256::from_be_slice(&encoded[..32]),
        U256::from(0x20),
        "a dynamic struct's `abi.encode` starts with the offset to its body"
    );
    // The first body word is the struct's first field, so the body starts exactly there.
    assert_eq!(
        Address::from_slice(&encoded[44..64]),
        Address::repeat_byte(0x11)
    );
}

// ───────────────────────── the bundle rule ─────────────────────────
//
// A bundle shaped like the one `RegistryBootstrapSequence.actions()` derives, over synthetic
// addresses, so the rule can be driven without a chain: the derived run, the authorities it
// touches, and what may or may not sit beside it.

const CTM: Address = Address::repeat_byte(0x01);
const CTM_ADMIN: Address = Address::repeat_byte(0x02);
const ECO_ADMIN: Address = Address::repeat_byte(0x03);
const CORE_EXECUTOR: Address = Address::repeat_byte(0x04);
const MIGRATION: Address = Address::repeat_byte(0x05);
const PUH: Address = Address::repeat_byte(0x07);
const ATTACKER: Address = Address::repeat_byte(0xBA);

/// `transferOwnership(address)`.
fn transfer_ownership(to: Address) -> Vec<u8> {
    let mut data = super::super::package::TRANSFER_OWNERSHIP_SELECTOR.to_vec();
    data.extend_from_slice(&to.into_word()[..]);
    data
}

fn action(label: &str, target: Address, data: Vec<u8>) -> views::BootstrapAction {
    views::BootstrapAction {
        label: label.to_string(),
        authority: "governance".to_string(),
        call: views::BootstrapCall {
            target,
            value: U256::ZERO,
            data: Bytes::from(data),
        },
    }
}

fn call(target: Address, data: Vec<u8>) -> GovernanceCall {
    GovernanceCall {
        target,
        value: U256::ZERO,
        data,
    }
}

fn completion_check() -> Vec<u8> {
    views::RegistryBootstrapMigrationView::validateAppliedCall {}.abi_encode()
}

fn derived_bundle() -> Vec<views::BootstrapAction> {
    vec![
        action(
            "hand the ecosystem ProxyAdmin to the bound core executor",
            ECO_ADMIN,
            transfer_ownership(CORE_EXECUTOR),
        ),
        action(
            "apply the pinned ecosystem inventory (applyL1Upgrade)",
            CORE_EXECUTOR,
            super::super::package::LegKind::Core.encode(CORE_TRANSITION),
        ),
        action(
            "nominate the migration as CTM owner",
            CTM,
            transfer_ownership(MIGRATION),
        ),
        action(
            "hand the CTM-domain ProxyAdmin to the migration",
            CTM_ADMIN,
            transfer_ownership(MIGRATION),
        ),
        action(
            "run the bootstrap edge",
            MIGRATION,
            super::super::package::MIGRATE_SELECTOR.to_vec(),
        ),
        action("check the edge completed", MIGRATION, completion_check()),
    ]
}

fn submitted_from(derived: &[views::BootstrapAction]) -> Vec<GovernanceCall> {
    derived
        .iter()
        .map(|a| call(a.call.target, a.call.data.to_vec()))
        .collect()
}

/// Every derived call is also a declared action: the prepare declares the whole sequence.
fn declared_from(derived: &[views::BootstrapAction]) -> Vec<ExternalAction> {
    derived
        .iter()
        .map(|a| {
            ExternalAction::governance(
                a.label.clone(),
                a.authority.clone(),
                &call(a.call.target, a.call.data.to_vec()),
            )
        })
        .collect()
}

fn authorities() -> BTreeMap<Address, String> {
    [
        (CTM, "the CTM"),
        (CTM_ADMIN, "the CTM-domain ProxyAdmin"),
        (ECO_ADMIN, "the ecosystem ProxyAdmin"),
        (CORE_EXECUTOR, "the core executor"),
        (MIGRATION, "the bootstrap migration"),
    ]
    .into_iter()
    .map(|(a, s)| (a, s.to_string()))
    .collect()
}

fn run_with(
    submitted: &[GovernanceCall],
    derived: &[views::BootstrapAction],
    declared: &[ExternalAction],
) -> VerificationResult {
    let mut result = VerificationResult::default();
    verify_bundle(
        submitted,
        derived,
        declared,
        &authorities(),
        MIGRATION,
        &mut result,
    );
    result
}

fn run(submitted: &[GovernanceCall], declared: &[ExternalAction]) -> VerificationResult {
    run_with(submitted, &derived_bundle(), declared)
}

#[test]
fn the_derived_run_alone_passes() {
    let derived = derived_bundle();
    let result = run(&submitted_from(&derived), &declared_from(&derived));
    assert_eq!(result.errors, 0);
    assert_eq!(result.warnings, 0);
}

/// THE finding: `coreExecutor.transferOwnership(attacker)` appended after the legitimate
/// run. The address is known (it takes two derived calls earlier in the run), the selector
/// is one the run itself uses, and the nominee would accept after the bundle and own the
/// ecosystem domain. It also sits after the completion check, which must end the bundle.
#[test]
fn a_nomination_appended_after_the_run_fails() {
    let derived = derived_bundle();
    let mut submitted = submitted_from(&derived);
    submitted.push(call(CORE_EXECUTOR, transfer_ownership(ATTACKER)));
    let result = run(&submitted, &declared_from(&derived));
    assert_eq!(result.errors, 2);
    assert!(result.ensure_success().is_err());
}

/// Declaring the nomination does not launder it: an authority takes exactly the derived
/// calls, and the package author controls the declarations.
#[test]
fn a_declared_nomination_on_an_authority_still_fails() {
    let derived = derived_bundle();
    let extra = call(CORE_EXECUTOR, transfer_ownership(ATTACKER));
    let mut submitted = vec![extra.clone()];
    submitted.extend(submitted_from(&derived));
    let mut declared = declared_from(&derived);
    declared.push(ExternalAction::governance(
        "bind the core executor",
        "governance",
        &extra,
    ));
    let result = run(&submitted, &declared);
    assert_eq!(result.errors, 1);
}

/// The same for every authority and any selector — a second nomination of the migration on
/// the CTM, a `forward`-shaped call on the migration, anything: a call to an authority is
/// not benign for being aimed at a known address.
#[test]
fn any_extra_call_to_an_authority_fails() {
    let derived = derived_bundle();
    for (target, data) in [
        (CTM, transfer_ownership(ATTACKER)),
        (CTM_ADMIN, vec![0xde, 0xad, 0xbe, 0xef]),
        (MIGRATION, vec![0x01, 0x02, 0x03, 0x04]),
        (
            CORE_EXECUTOR,
            super::super::package::LegKind::Core.encode(CORE_TRANSITION),
        ),
    ] {
        let mut submitted = submitted_from(&derived);
        submitted.insert(0, call(target, data));
        let result = run(&submitted, &declared_from(&derived));
        assert_eq!(result.errors, 1, "an extra call to {target} must fail");
    }
}

/// What the merge legitimately prepends — the governance-set wiring on the PUH — is a
/// declared action to a target outside the edge's authorities, and rides along.
#[test]
fn a_declared_prefix_outside_the_authorities_rides_along() {
    let derived = derived_bundle();
    let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
    let mut submitted = vec![wiring.clone()];
    submitted.extend(submitted_from(&derived));
    let mut declared = declared_from(&derived);
    declared.push(ExternalAction::governance(
        "wire the new governance set",
        "governance",
        &wiring,
    ));
    let result = run(&submitted, &declared);
    assert_eq!(result.errors, 0);
}

/// The same prefix UNDECLARED is the recurring path's rule, applied here too.
#[test]
fn an_undeclared_prefix_outside_the_authorities_fails() {
    let derived = derived_bundle();
    let mut submitted = vec![call(PUH, vec![0x99, 0x88, 0x77, 0x66])];
    submitted.extend(submitted_from(&derived));
    let result = run(&submitted, &declared_from(&derived));
    assert_eq!(result.errors, 1);
}

/// Nothing may follow the completion check, not even a declared call outside the
/// authorities: the check is the bundle's last word on whether the edge completed.
#[test]
fn a_declared_call_after_the_completion_check_fails() {
    let derived = derived_bundle();
    let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
    let mut submitted = submitted_from(&derived);
    submitted.push(wiring.clone());
    let mut declared = declared_from(&derived);
    declared.push(ExternalAction::governance("wiring", "governance", &wiring));
    let result = run(&submitted, &declared);
    assert_eq!(result.errors, 1);
}

/// An `admin` declaration rides no governance bundle, so it does not account for a call in
/// one.
#[test]
fn an_admin_declaration_does_not_count() {
    let derived = derived_bundle();
    let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
    let mut submitted = vec![wiring.clone()];
    submitted.extend(submitted_from(&derived));
    let mut declared = declared_from(&derived);
    let mut admin = ExternalAction::governance("wiring", "governance", &wiring);
    admin.phase = "admin".to_string();
    declared.push(admin);
    let result = run(&submitted, &declared);
    assert_eq!(result.errors, 1);
}

/// The run must be contiguous and in order: the handovers before `migrate()`.
#[test]
fn a_reordered_run_fails() {
    let derived = derived_bundle();
    let mut submitted = submitted_from(&derived);
    submitted.swap(3, 4);
    let result = run(&submitted, &declared_from(&derived));
    assert!(result.errors >= 1);
    assert!(result.ensure_success().is_err());
}

/// A derived call missing from the bundle is not a run at all — the completion check
/// included.
#[test]
fn a_dropped_derived_call_fails() {
    let derived = derived_bundle();
    for dropped in [2, derived.len() - 1] {
        let mut submitted = submitted_from(&derived);
        submitted.remove(dropped);
        let result = run(&submitted, &declared_from(&derived));
        assert!(result.errors >= 1, "dropping call {dropped} must fail");
    }
}

/// A sequence whose list does not end in `validateApplied()` on the migration is not the
/// reviewed bootstrap sequence describing this edge, even when the bundle matches it.
#[test]
fn a_sequence_not_ending_in_the_completion_check_fails() {
    let mut derived = derived_bundle();
    derived.pop();
    let result = run_with(
        &submitted_from(&derived),
        &derived,
        &declared_from(&derived),
    );
    assert_eq!(result.errors, 1);

    let mut elsewhere = derived_bundle();
    elsewhere.last_mut().unwrap().call.target = ATTACKER;
    let result = run_with(
        &submitted_from(&elsewhere),
        &elsewhere,
        &declared_from(&elsewhere),
    );
    assert_eq!(result.errors, 1);
}

// ───────────────────────── the sequence as an oracle ─────────────────────────

use super::super::construction::canonical_create2_address;
use alloy::providers::ProviderBuilder;
use alloy::transports::mock::Asserter;

const SALT: B256 = B256::repeat_byte(0x5A);
const CORE_TRANSITION: Address = Address::repeat_byte(0x08);

fn sequence_code() -> Vec<u8> {
    b"reviewed creation code of RegistryBootstrapSequence".to_vec()
}

fn build() -> ReviewedBuild {
    ReviewedBuild::from_parts(&[(
        "RegistryBootstrapSequence.sol",
        "RegistryBootstrapSequence",
        sequence_code(),
    )])
}

fn package() -> BootstrapPackage {
    BootstrapPackage {
        core_transition: Some(CORE_TRANSITION),
        release: Address::repeat_byte(0x09),
        migration: MIGRATION,
        reported_migration: None,
        reported_ctm_executor: None,
        reported_ctm: None,
        reported_ctm_proxy_admin: None,
        reported_singletons: Default::default(),
        ctm_key: "zksync_os".to_string(),
        calls: Vec::new(),
        external_actions: Vec::new(),
        create2_salts: Vec::new(),
        lifecycle: Default::default(),
        force_deployments_data: None,
        executor_records: Default::default(),
        member_records: Default::default(),
    }
}

fn genuine_sequence(salt: B256) -> Address {
    canonical_create2_address(
        salt,
        &sequence_code(),
        &constructor_args::registry_bootstrap_sequence(MIGRATION, CORE_TRANSITION),
    )
}

async fn locate(
    asserter: &Asserter,
    package: &BootstrapPackage,
    salts: &[B256],
) -> (
    Option<Address>,
    VerificationResult,
    BTreeMap<Address, String>,
) {
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    let mut reviewed = BTreeMap::new();
    let sequence = locate_sequence(
        &provider,
        &build(),
        &mut result,
        package,
        salts,
        &mut reviewed,
    )
    .await
    .unwrap();
    (sequence, result, reviewed)
}

/// The oracle the bundle is compared against is DERIVED from the reviewed creation code over
/// the migration and core transition, never read from the package — so it is established by
/// construction, and only then is its list read and the bundle held against it.
#[tokio::test]
async fn the_derived_sequence_is_established_and_then_consulted() {
    let genuine = genuine_sequence(SALT);
    let mut package = package();
    let derived = derived_bundle();
    package.calls = submitted_from(&derived);
    package.external_actions = declared_from(&derived);

    let asserter = Asserter::new();
    asserter.push_success(&Bytes::from_static(&[0x60, 0x00])); // code at the derived address
    asserter.push_success(&Bytes::from(derived.abi_encode()));
    let (sequence, mut result, reviewed) = locate(&asserter, &package, &[SALT]).await;
    assert_eq!(sequence, Some(genuine));
    assert_eq!(reviewed.len(), 1);

    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut authorities = authorities();
    authorities.insert(genuine, "the bootstrap sequence".to_string());
    verify_derived_sequence(&provider, &mut result, &package, sequence, &authorities).await;
    assert!(asserter.read_q().is_empty(), "the list was read");
    assert_eq!(
        result.errors, 0,
        "a bundle that IS the derived sequence passes"
    );
}

/// The sequence is found under whichever reviewed salt built it.
#[tokio::test]
async fn the_sequence_is_found_under_the_salt_that_built_it() {
    let other_salt = B256::repeat_byte(0x11);
    let asserter = Asserter::new();
    asserter.push_success(&Bytes::new()); // nothing under the first salt
    asserter.push_success(&Bytes::from_static(&[0x60, 0x00]));
    let (sequence, result, _) = locate(&asserter, &package(), &[other_salt, SALT]).await;
    assert_eq!(sequence, Some(genuine_sequence(SALT)));
    assert_eq!(result.errors, 0);
}

/// Nothing deployed at the derived address: an error, and no list is ever read — the queued
/// list answer stays unconsumed.
#[tokio::test]
async fn an_undeployed_sequence_is_never_consulted() {
    let asserter = Asserter::new();
    asserter.push_success(&Bytes::new());
    asserter.push_success(&Bytes::from(
        Vec::<views::BootstrapAction>::new().abi_encode(),
    ));
    let package = package();
    let (sequence, mut result, reviewed) = locate(&asserter, &package, &[SALT]).await;
    assert_eq!(sequence, None);
    assert_eq!(result.errors, 1);
    assert!(reviewed.is_empty());

    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    verify_derived_sequence(&provider, &mut result, &package, sequence, &BTreeMap::new()).await;
    assert_eq!(asserter.read_q().len(), 1, "no list may be read");
    assert_eq!(result.errors, 2);
}

/// A bootstrap package without a core transition has nothing to derive the sequence over:
/// an error, not a sequence taken on trust.
#[tokio::test]
async fn a_sequence_without_a_core_transition_is_unverifiable() {
    let mut package = package();
    package.core_transition = None;
    let (sequence, result, _) = locate(&Asserter::new(), &package, &[SALT]).await;
    assert_eq!(sequence, None);
    assert_eq!(result.errors, 1);
}

// ───────────────────────── the ServerNotifier handover ─────────────────────────
//
// The facts as the chain reports them at review time, judged against a manifest whose
// mandatory notifier row names NOTIFIER. Every state short of "complete", or "nominated and
// accepted by the bundle's derived first call", must be an error: `migrate()` refuses it.

const NOTIFIER: Address = Address::repeat_byte(0x2A);
const CTM_EXECUTOR: Address = Address::repeat_byte(0x2B);
const CHAIN_ADMIN: Address = Address::repeat_byte(0x2C);
const DEPLOYER: Address = Address::repeat_byte(0x2D);
const OLD_NOTIFIER_ADMIN: Address = Address::repeat_byte(0x2E);

fn notifier_row() -> ProxyUpgradeRow {
    ProxyUpgradeRow {
        proxy: NOTIFIER,
        expectedOldImpl: Address::repeat_byte(0x3A),
        implNew: Address::repeat_byte(0x3B),
        callInitializeUpgrade: false,
    }
}

fn inert_row() -> ProxyUpgradeRow {
    ProxyUpgradeRow {
        proxy: Address::ZERO,
        expectedOldImpl: Address::ZERO,
        implNew: Address::ZERO,
        callInitializeUpgrade: false,
    }
}

fn manifest_with(notifier: ProxyUpgradeRow) -> views::BootstrapManifest {
    let mut proxy_upgrades = vec![inert_row(); CTM_CONTRACT_SERVER_NOTIFIER_SLOT + 1];
    proxy_upgrades[CTM_CONTRACT_SERVER_NOTIFIER_SLOT] = notifier;
    views::BootstrapManifest {
        ctm: CTM,
        expectedProtocolVersion: U256::from(1),
        ctmProxyAdmin: CTM_ADMIN,
        ctmProxyUpgrades: proxy_upgrades,
        currentRelease: Address::repeat_byte(0x33),
        oldProtocolVersionDeadline: U256::ZERO,
        upgradeEngine: Address::repeat_byte(0x44),
        l2Plan: views::AuthoredL2Plan {
            delegateBytecodeInfo: Default::default(),
            extraBytecodeInfos: Vec::new(),
            delegateComposer: Address::ZERO,
        },
        upgradeTimestamp: U256::ZERO,
        ctmExecutor: CTM_EXECUTOR,
        coreExecutor: Address::repeat_byte(0x67),
        governance: Address::repeat_byte(0x66),
    }
}

/// A notifier bound to the manifest's CTM, with the given authority state.
fn notifier_facts(owner: Address, pending_owner: Address, proxy_admin: Address) -> NotifierFacts {
    NotifierFacts {
        notifier: NOTIFIER,
        ctm_notifier: Some(NOTIFIER),
        notifier_ctm: Some(CTM),
        proxy_admin,
        owner: Some(owner),
        pending_owner: Some(pending_owner),
    }
}

fn judge(facts: &NotifierFacts, bundle: &[GovernanceCall]) -> (VerificationResult, bool) {
    let mut result = VerificationResult::default();
    let verdict =
        judge_notifier_handover(&mut result, facts, &manifest_with(notifier_row()), bundle);
    (result, verdict.under_ctm_proxy_admin)
}

fn accepting_bundle() -> Vec<GovernanceCall> {
    vec![notifier_acceptance(CTM_EXECUTOR, NOTIFIER)]
}

#[test]
fn a_completed_handover_passes() {
    let facts = notifier_facts(CTM_EXECUTOR, Address::ZERO, CTM_ADMIN);
    let (result, readable) = judge(&facts, &[]);
    assert_eq!(result.errors, 0);
    assert!(readable);
}

/// The ChainAdmin moved the proxy and nominated the executor; governance's acceptance is the
/// bundle's first derived call, and the bundle carries it.
#[test]
fn a_nomination_the_bundle_accepts_passes() {
    let facts = notifier_facts(CHAIN_ADMIN, CTM_EXECUTOR, CTM_ADMIN);
    let (result, readable) = judge(&facts, &accepting_bundle());
    assert_eq!(result.errors, 0);
    assert!(readable);
}

#[test]
fn a_nomination_the_bundle_does_not_accept_fails() {
    let facts = notifier_facts(CHAIN_ADMIN, CTM_EXECUTOR, CTM_ADMIN);
    let (result, _) = judge(&facts, &[]);
    assert_eq!(result.errors, 1);
}

/// The frozen v34 fixture before the ChainAdmin acted: the deployer still owns the notifier
/// with the ChainAdmin nominated (never accepted), and the proxy sits under its own
/// ChainAdmin-owned ProxyAdmin. Both halves are reported, and the notifier row is marked
/// unreadable through the CTM-domain admin.
#[test]
fn the_untouched_v34_notifier_is_the_missing_chain_admin_half() {
    let facts = notifier_facts(DEPLOYER, CHAIN_ADMIN, OLD_NOTIFIER_ADMIN);
    let (result, readable) = judge(&facts, &accepting_bundle());
    assert_eq!(result.errors, 2);
    assert!(!readable);
    assert!(result.ensure_success().is_err());
}

/// The bundle was prepared while the nomination was pending, and governance accepted
/// outside it since: the bundle would revert on its own first derived call.
#[test]
fn an_acceptance_of_an_already_accepted_ownership_fails() {
    let facts = notifier_facts(CTM_EXECUTOR, Address::ZERO, CTM_ADMIN);
    let (result, _) = judge(&facts, &accepting_bundle());
    assert_eq!(result.errors, 1);
}

#[test]
fn a_nomination_outstanding_after_the_acceptance_fails() {
    let facts = notifier_facts(CTM_EXECUTOR, ATTACKER, CTM_ADMIN);
    let (result, _) = judge(&facts, &[]);
    assert_eq!(result.errors, 1);
}

#[test]
fn a_notifier_bound_to_another_ctm_fails_both_ways() {
    let mut facts = notifier_facts(CTM_EXECUTOR, Address::ZERO, CTM_ADMIN);
    facts.ctm_notifier = Some(Address::repeat_byte(0x4A));
    facts.notifier_ctm = Some(Address::repeat_byte(0x4B));
    let (result, _) = judge(&facts, &[]);
    assert_eq!(result.errors, 2);
}

/// The acceptance is `RegistryBootstrapSequence.actions()`' first call while the handover is
/// pending: `forward(Call[])` on the executor wrapping `acceptOwnership()` on the notifier.
#[test]
fn the_acceptance_forwards_accept_ownership_to_the_notifier() {
    let call = notifier_acceptance(CTM_EXECUTOR, NOTIFIER);
    assert_eq!(call.target, CTM_EXECUTOR);
    assert_eq!(
        &call.data[..4],
        &alloy::primitives::keccak256(b"forward((address,uint256,bytes)[])")[..4]
    );
    let decoded = CTMUpgradeExecutorView::forwardCall::abi_decode(&call.data).unwrap();
    assert_eq!(decoded._calls.len(), 1);
    assert_eq!(decoded._calls[0].target, NOTIFIER);
    assert_eq!(
        &decoded._calls[0].data[..],
        &alloy::primitives::keccak256(b"acceptOwnership()")[..4]
    );
}

#[tokio::test]
async fn a_manifest_without_the_notifier_row_is_an_error() {
    let asserter = Asserter::new();
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    let verdict =
        verify_notifier_handover(&provider, &mut result, &manifest_with(inert_row()), &[])
            .await
            .unwrap();
    assert_eq!(result.errors, 1);
    assert!(!verdict.under_ctm_proxy_admin);
}

/// The live read path, in the order it queries: the proxy's EIP-1967 admin slot (an address
/// in the low 20 bytes of the word), then the four getters.
#[tokio::test]
async fn the_handover_is_read_from_the_admin_slot_and_the_getters() {
    let asserter = Asserter::new();
    asserter.push_success(&U256::from_be_bytes(CTM_ADMIN.into_word().0));
    for answer in [NOTIFIER, CTM, CTM_EXECUTOR, Address::ZERO] {
        asserter.push_success(&Bytes::from(answer.abi_encode()));
    }
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    let verdict =
        verify_notifier_handover(&provider, &mut result, &manifest_with(notifier_row()), &[])
            .await
            .unwrap();
    assert!(asserter.read_q().is_empty());
    assert_eq!(result.errors, 0);
    assert!(verdict.under_ctm_proxy_admin);
}

// ───────────────────────── executor records ─────────────────────────

/// The records a v35 bootstrap prepare writes for the manifest's own executors.
fn records_for(manifest: &views::BootstrapManifest) -> UpgradeExecutorsRecord {
    use crate::common::forge::scripts::upgrade_executors::{CoreExecutorRecord, CtmExecutorRecord};
    UpgradeExecutorsRecord {
        core_executor: Some(CoreExecutorRecord {
            address: manifest.coreExecutor,
            create2_salt: SALT,
            initial_owner: manifest.governance,
            proxy_admin: ECO_ADMIN,
        }),
        ctm_executor: Some(CtmExecutorRecord {
            address: manifest.ctmExecutor,
            create2_salt: SALT,
            initial_owner: manifest.governance,
            chain_type_manager: manifest.ctm,
            ctm_proxy_admin: manifest.ctmProxyAdmin,
        }),
    }
}

fn judge_records(records: &UpgradeExecutorsRecord) -> VerificationResult {
    let mut result = VerificationResult::default();
    judge_executor_records_against_manifest(&mut result, records, &manifest_with(notifier_row()));
    result
}

#[test]
fn records_of_the_manifests_executors_pass() {
    let records = records_for(&manifest_with(notifier_row()));
    assert_eq!(judge_records(&records).errors, 0);
    assert_eq!(judge_records(&UpgradeExecutorsRecord::default()).errors, 0);
}

/// A record of another deployment — another executor than the edge hands a domain to — is
/// refused before anything is re-derived from it.
#[test]
fn records_of_another_deployment_fail() {
    let manifest = manifest_with(notifier_row());
    let mut records = records_for(&manifest);
    records.core_executor.as_mut().unwrap().address = ATTACKER;
    let result = judge_records(&records);
    assert_eq!(result.errors, 1);
    assert!(result.has_error("describes another deployment"));

    let mut records = records_for(&manifest);
    records.core_executor.as_mut().unwrap().address = ATTACKER;
    records.ctm_executor.as_mut().unwrap().address = ATTACKER;
    assert_eq!(judge_records(&records).errors, 2);
}

// ───────────────────────── the freeze authority ─────────────────────────

const CTM_BRIDGEHUB: Address = Address::repeat_byte(0xB1);

/// Runs the freeze-authority check over a CTM whose Bridgehub answers `owner` (or reverts).
async fn judge_freeze_authority(owner: Option<Address>) -> VerificationResult {
    let asserter = Asserter::new();
    asserter.push_success(&Bytes::from(CTM_BRIDGEHUB.abi_encode()));
    match owner {
        Some(owner) => asserter.push_success(&Bytes::from(owner.abi_encode())),
        None => asserter.push_failure_msg("execution reverted"),
    }
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    verify_freeze_authority(&provider, &mut result, &manifest_with(notifier_row())).await;
    assert!(asserter.read_q().is_empty(), "both reads were made");
    result
}

/// The CTM's Bridgehub, read through the CTM, is owned by the manifest's governance: the
/// direct freeze route answers to the same governance as the executors.
#[tokio::test]
async fn a_bridgehub_owned_by_the_manifests_governance_passes() {
    let governance = manifest_with(notifier_row()).governance;
    let result = judge_freeze_authority(Some(governance)).await;
    assert_eq!((result.errors, result.warnings), (0, 0));
}

/// Any other Bridgehub owner could freeze and unfreeze the CTM's chains without governance.
#[tokio::test]
async fn a_bridgehub_owned_by_anyone_else_fails() {
    let result = judge_freeze_authority(Some(ATTACKER)).await;
    assert_eq!(result.errors, 1);
    assert!(result.has_error("not by the manifest's governance"));
}

/// An owner that cannot be read cannot be held to governance.
#[tokio::test]
async fn an_unreadable_bridgehub_owner_fails() {
    let result = judge_freeze_authority(None).await;
    assert_eq!(result.errors, 1);
    assert!(result.has_error("could not be read"));
}

// ───────────────────────── chains below the departing version ─────────────────────────

/// v0.34.0 and v0.33.0 in the packed encoding.
const V34: u64 = 0x22_0000_0000;
const V33: u64 = 0x21_0000_0000;

fn chain(chain_id: u64, protocol_version: Option<u64>) -> ChainVersion {
    ChainVersion {
        chain_id: U256::from(chain_id),
        protocol_version: protocol_version.map(U256::from),
        verifier: None,
    }
}

fn judge_chains(chains: &[ChainVersion]) -> VerificationResult {
    let mut result = VerificationResult::default();
    judge_lagging_chains(&mut result, U256::from(V34), chains);
    result
}

#[test]
fn chains_at_the_departing_version_report_nothing() {
    let result = judge_chains(&[chain(270, Some(V34)), chain(271, Some(V34))]);
    assert_eq!((result.errors, result.warnings), (0, 0));
    let result = judge_chains(&[]);
    assert_eq!((result.errors, result.warnings), (0, 0));
}

/// Informational: every lagging chain is named as a warning, and none of it fails the run.
#[test]
fn each_chain_below_the_departing_version_is_a_warning() {
    let result = judge_chains(&[
        chain(270, Some(V34)),
        chain(271, Some(V33)),
        chain(272, Some(V33)),
    ]);
    assert_eq!((result.errors, result.warnings), (0, 2));
    assert!(result.ensure_success().is_ok());
}

/// An unreadable version was warned about when it was read, so the verdict adds nothing for
/// it — but it also does not claim that no chain lags.
#[test]
fn an_unreadable_chain_is_neither_lagging_nor_cleared() {
    let result = judge_chains(&[chain(270, None)]);
    assert_eq!((result.errors, result.warnings), (0, 0));
}

/// The live read path, in the order it queries: the CTM's Bridgehub, its chain ids, then per
/// chain its CTM and — for this CTM's chains only — the version the CTM reports, and for a
/// chain at the departing version its diamond and the verifier it runs: the verifier a
/// bootstrap release may carry over.
#[tokio::test]
async fn the_chains_are_enumerated_through_the_bridgehub_and_filtered_by_ctm() {
    const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
    const OTHER_CTM: Address = Address::repeat_byte(0xC1);
    const DIAMOND: Address = Address::repeat_byte(0xD1);
    const LIVE_VERIFIER: Address = Address::repeat_byte(0xFE);
    let asserter = Asserter::new();
    asserter.push_success(&Bytes::from(BRIDGEHUB.abi_encode()));
    let ids = vec![U256::from(270u64), U256::from(271u64), U256::from(272u64)];
    asserter.push_success(&Bytes::from(ids.abi_encode()));
    asserter.push_success(&Bytes::from(CTM.abi_encode()));
    asserter.push_success(&Bytes::from(U256::from(V34).abi_encode()));
    asserter.push_success(&Bytes::from(DIAMOND.abi_encode()));
    asserter.push_success(&Bytes::from(LIVE_VERIFIER.abi_encode()));
    asserter.push_success(&Bytes::from(OTHER_CTM.abi_encode()));
    asserter.push_success(&Bytes::from(CTM.abi_encode()));
    asserter.push_success(&Bytes::from(U256::from(V33).abi_encode()));
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    let chains = read_chain_versions(&provider, &mut result, CTM, U256::from(V34)).await;
    assert!(asserter.read_q().is_empty());
    assert_eq!((result.errors, result.warnings), (0, 0));
    let read: Vec<(U256, Option<U256>, Option<Address>)> = chains
        .iter()
        .map(|c| (c.chain_id, c.protocol_version, c.verifier))
        .collect();
    assert_eq!(
        read,
        vec![
            (
                U256::from(270u64),
                Some(U256::from(V34)),
                Some(LIVE_VERIFIER)
            ),
            (U256::from(272u64), Some(U256::from(V33)), None),
        ]
    );
}
