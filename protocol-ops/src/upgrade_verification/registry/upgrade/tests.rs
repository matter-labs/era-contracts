use super::*;
use alloy::primitives::Bytes;
use alloy::providers::ProviderBuilder;
use alloy::sol_types::SolCall;
use alloy::transports::mock::Asserter;

use super::super::construction::canonical_create2_address;
use super::super::package::{recover_legs, LifecycleInputs};
use super::super::provenance::CodeIdentity;
use super::super::views::{CTMUpgradeExecutorView, ProxyUpgradeTransitionManifest};
use crate::upgrade_verification::constants::{
    CTM_CONTRACTS, L1_ECOSYSTEM_CONTRACTS, PROXY_UPGRADE_DOMAIN_CORE, PROXY_UPGRADE_DOMAIN_CTM,
};

const CORE_EXECUTOR: Address = Address::repeat_byte(0xE0);
const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);
const CORE_TRANSITION: Address = Address::repeat_byte(0xEE);
const INFRASTRUCTURE: Address = Address::repeat_byte(0x1F);
const TRANSITION: Address = Address::repeat_byte(0xCC);
const CTM: Address = Address::repeat_byte(0xC7);
const CTM_ADMIN: Address = Address::repeat_byte(0xA7);
const ECO_ADMIN: Address = Address::repeat_byte(0xA0);
const PUH: Address = Address::repeat_byte(0x07);
const STRANGER: Address = Address::repeat_byte(0x99);

fn leg_call(kind: LegKind, executor: Address, object: Address) -> GovernanceCall {
    GovernanceCall {
        target: executor,
        value: U256::ZERO,
        data: kind.encode(object),
    }
}

fn core() -> GovernanceCall {
    leg_call(LegKind::Core, CORE_EXECUTOR, CORE_TRANSITION)
}

fn infrastructure() -> GovernanceCall {
    leg_call(LegKind::Infrastructure, CTM_EXECUTOR, INFRASTRUCTURE)
}

fn transition() -> GovernanceCall {
    leg_call(LegKind::Transition, CTM_EXECUTOR, TRANSITION)
}

fn wiring(byte: u8) -> GovernanceCall {
    GovernanceCall {
        target: PUH,
        value: U256::ZERO,
        data: vec![0x99, 0x88, 0x77, byte],
    }
}

fn declared(calls: &[GovernanceCall]) -> Vec<ExternalAction> {
    calls
        .iter()
        .map(|call| ExternalAction::governance("an external action", "governance", call))
        .collect()
}

/// A package as the loader would hand it over for `calls`, with every summary field naming
/// exactly the legs `calls` carries. Built directly rather than loaded, so the order and
/// contiguity rules the LOADER does not judge can be driven here.
fn package(calls: Vec<GovernanceCall>, external_actions: Vec<ExternalAction>) -> UpgradePackage {
    let legs = recover_legs(&calls).expect("well-formed legs");
    let reported = |kind: LegKind| {
        legs.iter()
            .find(|leg| leg.kind == kind)
            .map(|leg| leg.object)
    };
    UpgradePackage {
        ctm_key: Some("zksync_os".to_string()),
        reported_core_transition: reported(LegKind::Core),
        reported_infrastructure_transition: reported(LegKind::Infrastructure),
        reported_ctm_transition: reported(LegKind::Transition),
        reported_ctm_executor: Some(CTM_EXECUTOR),
        reported_ctm: Some(CTM),
        reported_ctm_proxy_admin: Some(CTM_ADMIN),
        reported_singletons: Default::default(),
        external_actions,
        create2_salts: Vec::new(),
        lifecycle: LifecycleInputs {
            core_executor: Some(CORE_EXECUTOR),
            core_proxy_admin: Some(ECO_ADMIN),
        },
        force_deployments_data: None,
        executor_records: Default::default(),
        member_records: Default::default(),
        legs,
        calls,
    }
}

/// The authorities as `upgrade_authorities` collects them for these synthetic addresses.
fn authorities(package: &UpgradePackage) -> BTreeMap<Address, String> {
    upgrade_authorities(
        package,
        &LifecycleBindings {
            core_proxy_admin: Some(ECO_ADMIN),
            ctm: Some(CTM),
            ctm_proxy_admin: Some(CTM_ADMIN),
        },
        &BTreeMap::new(),
    )
}

fn judge(package: &UpgradePackage) -> VerificationResult {
    let mut result = VerificationResult::default();
    verify_upgrade_calls(package, &authorities(package), &mut result);
    result
}

/// The canonical run — every non-empty subsequence of core -> infrastructure -> transition —
/// passes, alone in the bundle.
#[test]
fn every_canonical_run_passes() {
    let all = [core(), infrastructure(), transition()];
    for mask in 1u8..8 {
        let calls: Vec<GovernanceCall> = all
            .iter()
            .enumerate()
            .filter(|(i, _)| mask & (1 << i) != 0)
            .map(|(_, call)| call.clone())
            .collect();
        let result = judge(&package(calls, Vec::new()));
        assert_eq!(
            (result.errors, result.warnings),
            (0, 0),
            "subsequence {mask:03b}"
        );
    }
}

/// Q5 swapped order: the transition committed before the infrastructure it may need.
#[test]
fn a_swapped_order_fails() {
    for calls in [
        vec![transition(), infrastructure()],
        vec![infrastructure(), core()],
        vec![core(), transition(), infrastructure()],
    ] {
        let result = judge(&package(calls, Vec::new()));
        assert!(
            result.has_error("swapped order"),
            "{:?}",
            result.error_messages
        );
        assert_eq!(result.errors, 1);
    }
}

/// Q5 a leg not contiguous: another instruction between two domains' legs fails even when it
/// is a declared external action outside the authorities.
#[test]
fn a_run_interrupted_by_another_call_fails() {
    let extra = wiring(0x01);
    let result = judge(&package(
        vec![core(), extra.clone(), transition()],
        declared(std::slice::from_ref(&extra)),
    ));
    assert!(
        result.has_error("not one contiguous run"),
        "{:?}",
        result.error_messages
    );
    assert_eq!(result.errors, 1);
}

/// The merger's extras precede the run and a CTM prepare's declared actions follow it; each,
/// declared in emission order, rides along.
#[test]
fn declared_external_actions_around_the_run_ride_along() {
    let before = wiring(0x01);
    let after = wiring(0x02);
    let result = judge(&package(
        vec![before.clone(), core(), transition(), after.clone()],
        declared(&[before, after]),
    ));
    assert_eq!((result.errors, result.warnings), (0, 0));
}

/// A call nobody declared rides along with a perfectly good run: it fails the run.
#[test]
fn an_undeclared_call_fails() {
    let result = judge(&package(vec![core(), wiring(0x01)], Vec::new()));
    assert!(
        result.has_error("neither a leg of this upgrade nor a declared"),
        "{:?}",
        result.error_messages
    );
    assert_eq!(result.errors, 1);
}

/// Multiplicity: a declaration accounts for exactly one call.
#[test]
fn a_declared_action_carried_twice_fails() {
    let extra = wiring(0x01);
    let result = judge(&package(
        vec![extra.clone(), extra.clone(), core()],
        declared(std::slice::from_ref(&extra)),
    ));
    assert!(
        result.has_error("more often than it is declared"),
        "{:?}",
        result.error_messages
    );
    assert_eq!(result.errors, 1);
}

/// A declaration the bundle never carries describes a call governance would not sign.
#[test]
fn a_declared_action_missing_from_the_bundle_fails() {
    let result = judge(&package(vec![core()], declared(&[wiring(0x01)])));
    assert!(
        result.has_error("never carries"),
        "{:?}",
        result.error_messages
    );
    assert_eq!(result.errors, 1);
}

/// Position: the declared actions in another order than declared are not the bundle the
/// prepares emitted.
#[test]
fn declared_actions_out_of_their_declared_order_fail() {
    let (first, second) = (wiring(0x01), wiring(0x02));
    let result = judge(&package(
        vec![second.clone(), first.clone(), core()],
        declared(&[first, second]),
    ));
    assert!(
        result.has_error("out of their declared order"),
        "{:?}",
        result.error_messages
    );
    assert_eq!(result.errors, 1);
}

/// An `admin` declaration rides no governance bundle, so it does not account for a call in it.
#[test]
fn an_admin_declaration_does_not_account_for_a_bundle_call() {
    let extra = wiring(0x01);
    let mut admin = ExternalAction::governance("an admin hop", "governance", &extra);
    admin.phase = "admin".to_string();
    let result = judge(&package(vec![core(), extra], vec![admin]));
    assert!(result.has_error("neither a leg of this upgrade nor a declared"));
    assert_eq!(result.errors, 1);
}

/// Declaring a call does not launder it when it reaches one of the upgrade's authorities —
/// a nomination on the CTM, a call into either ProxyAdmin or into an object.
#[test]
fn a_declared_call_to_an_authority_outside_the_run_fails() {
    let nominate = |target: Address| GovernanceCall {
        target,
        value: U256::ZERO,
        data: [vec![0xf2, 0xfd, 0xe3, 0x8b], STRANGER.into_word().to_vec()].concat(),
    };
    for target in [CTM, CTM_ADMIN, ECO_ADMIN, TRANSITION] {
        let extra = nominate(target);
        let result = judge(&package(
            vec![extra.clone(), transition()],
            declared(std::slice::from_ref(&extra)),
        ));
        assert!(
            result.has_error("outside the run of legs"),
            "{target}: {:?}",
            result.error_messages
        );
        // The authority call, and its now-unmatched declaration.
        assert_eq!(result.errors, 2, "{target}");
    }
}

/// The bundle applies another object than the reviewed one the summary names: the re-encoded
/// run is not in the bundle. (The loader refuses this first; the verifier holds independently.)
#[test]
fn a_substituted_object_is_not_the_reviewed_run() {
    let mut pkg = package(vec![transition()], Vec::new());
    pkg.reported_ctm_transition = Some(STRANGER);
    let result = judge(&pkg);
    assert!(
        result.has_error("do not contain the 1 reviewed leg(s)"),
        "{:?}",
        result.error_messages
    );
}

/// A leg carrying value is not the call the merge derives, and the entrypoints are not
/// payable. (The loader refuses this first; the verifier holds independently.)
#[test]
fn a_leg_carrying_value_is_not_the_reviewed_run() {
    let mut pkg = package(vec![core()], Vec::new());
    pkg.calls[0].value = U256::from(1);
    let result = judge(&pkg);
    assert!(
        result.has_error("do not contain the 1 reviewed leg(s)"),
        "{:?}",
        result.error_messages
    );
}

/// A leg whose executor the summaries do not name cannot be re-encoded from reviewed values:
/// it is not silently left out of the expected run. (The loader refuses this first.)
#[test]
fn a_leg_the_summaries_do_not_account_for_fails() {
    let mut pkg = package(vec![core()], Vec::new());
    pkg.lifecycle.core_executor = None;
    let result = judge(&pkg);
    assert!(
        result.has_error("the summaries do not account for"),
        "{:?}",
        result.error_messages
    );
}

/// The re-encoding the verifier compares against is the executors' real ABI, transcribed
/// independently of the `sol!` mirror both sides use.
#[test]
fn the_reencoded_legs_are_the_executors_calls() {
    let call = core();
    assert_eq!(&call.data[..4], &[0x60, 0x93, 0xa2, 0x59]);
    assert_eq!(&call.data[16..], CORE_TRANSITION.as_slice());
    assert_eq!(
        CTMUpgradeExecutorView::applyInfrastructureUpgradeCall::SELECTOR,
        [0x68, 0xe9, 0x89, 0x78]
    );
    assert_eq!(
        CTMUpgradeExecutorView::applyCTMUpgradeCall::SELECTOR,
        [0x7b, 0x1b, 0x71, 0x6a]
    );
}

#[test]
fn a_reported_field_disagreeing_with_what_executes_is_an_error() {
    let mut result = VerificationResult::default();
    cross_check(
        &mut result,
        "ctm_transition_addr",
        Some(Address::repeat_byte(0x11)),
        Some(Address::repeat_byte(0x22)),
        "the transition",
    );
    assert!(result.has_error("describes a different object"));
    assert_eq!(result.errors, 1);
}

#[test]
fn an_agreeing_report_passes_and_an_absent_one_warns() {
    let mut result = VerificationResult::default();
    let same = Address::repeat_byte(0x11);
    cross_check(&mut result, "f", Some(same), Some(same), "the transition");
    assert_eq!((result.errors, result.warnings), (0, 0));
    cross_check(&mut result, "f", None, Some(same), "the transition");
    assert_eq!(result.warnings, 1);
    cross_check(&mut result, "f", None, None, "the transition");
    assert_eq!(result.warnings, 1);
}

// ───────────────────────── the domain-tagged inventory object ─────────────────────────

const SALT: B256 = B256::repeat_byte(0x5A);
const TRANSITION_RUNTIME: &[u8] = b"the reviewed ProxyUpgradeTransition runtime";

fn transition_code() -> Vec<u8> {
    b"reviewed creation code of ProxyUpgradeTransition".to_vec()
}

fn reviewed_build() -> ReviewedBuild {
    ReviewedBuild::from_artifacts(
        CodeIdentity::empty()
            .with_contract("l1-contracts/ProxyUpgradeTransition", TRANSITION_RUNTIME),
        vec![(
            "ProxyUpgradeTransition.sol",
            "ProxyUpgradeTransition",
            transition_code(),
            TRANSITION_RUNTIME.to_vec(),
            Vec::new(),
        )],
    )
}

fn inert() -> ProxyUpgradeRow {
    ProxyUpgradeRow {
        proxy: Address::ZERO,
        expectedOldImpl: Address::ZERO,
        implNew: Address::ZERO,
        callInitializeUpgrade: false,
    }
}

/// A manifest of `domain` over an inventory of `slots` slots, the first one participating.
fn manifest(domain: u8, slots: usize) -> ProxyUpgradeTransitionManifest {
    let mut rows = vec![inert(); slots];
    rows[0] = ProxyUpgradeRow {
        proxy: Address::repeat_byte(0x01),
        expectedOldImpl: Address::repeat_byte(0x02),
        implNew: Address::repeat_byte(0x03),
        callInitializeUpgrade: false,
    };
    ProxyUpgradeTransitionManifest {
        domain,
        proxyUpgrades: rows,
    }
}

/// Serves `manifest` from a genuinely constructed object and verifies it as `expected`.
async fn verify_object(
    manifest: &ProxyUpgradeTransitionManifest,
    expected: Inventory,
) -> (
    Option<Vec<ProxyUpgradeRow>>,
    VerificationResult,
    BTreeMap<Address, String>,
    Address,
) {
    let address = canonical_create2_address(SALT, &transition_code(), &manifest.abi_encode());
    let asserter = Asserter::new();
    asserter.push_success(&Bytes::from_static(TRANSITION_RUNTIME));
    asserter.push_success(&Bytes::from(manifest.abi_encode()));
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    let mut reviewed = BTreeMap::new();
    let rows = verify_proxy_upgrade_transition(
        &provider,
        &reviewed_build(),
        &mut result,
        "the object",
        address,
        expected,
        &[SALT],
        &mut reviewed,
    )
    .await
    .unwrap();
    assert!(asserter.read_q().is_empty());
    (rows, result, reviewed, address)
}

/// A genuine object of the leg's domain: its construction re-derives (the constructor argument
/// is `abi.encode(ProxyUpgradeTransitionManifest)`, domain included) and its whole inventory is
/// handed to the slot checks.
#[tokio::test]
async fn an_object_of_the_legs_domain_verifies_and_yields_its_inventory() {
    for (domain, slots, expected) in [
        (
            PROXY_UPGRADE_DOMAIN_CORE,
            L1_ECOSYSTEM_CONTRACTS.len(),
            Inventory::Ecosystem,
        ),
        (
            PROXY_UPGRADE_DOMAIN_CTM,
            CTM_CONTRACTS.len(),
            Inventory::CtmDomain,
        ),
    ] {
        let manifest = manifest(domain, slots);
        let (rows, result, reviewed, address) = verify_object(&manifest, expected).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
        assert_eq!(rows.map(|rows| rows.len()), Some(slots));
        assert!(reviewed.contains_key(&address));
    }
}

/// Q5 wrong domain: a CTM-domain object on the core leg (and the reverse) is refused against
/// the domain the LEG fixes — never the one the object claims — and yields no inventory.
#[tokio::test]
async fn an_object_of_another_domain_fails() {
    for (domain, slots, expected) in [
        (
            PROXY_UPGRADE_DOMAIN_CTM,
            CTM_CONTRACTS.len(),
            Inventory::Ecosystem,
        ),
        (
            PROXY_UPGRADE_DOMAIN_CORE,
            L1_ECOSYSTEM_CONTRACTS.len(),
            Inventory::CtmDomain,
        ),
    ] {
        let (rows, result, _, _) = verify_object(&manifest(domain, slots), expected).await;
        assert!(
            result.has_error("ProxyUpgradeDomainMismatch"),
            "{:?}",
            result.error_messages
        );
        assert_eq!(result.errors, 1);
        assert!(rows.is_none());
    }
}

/// The constructor argument the address derivation feeds in is Solidity's
/// `abi.encode(manifest)`: a dynamic struct, so an offset word, then the domain word.
#[test]
fn a_proxy_upgrade_manifest_encodes_as_solidity_abi_encode() {
    let encoded = manifest(PROXY_UPGRADE_DOMAIN_CTM, CTM_CONTRACTS.len()).abi_encode();
    assert_eq!(U256::from_be_slice(&encoded[..32]), U256::from(0x20));
    assert_eq!(
        U256::from_be_slice(&encoded[32..64]),
        U256::from(PROXY_UPGRADE_DOMAIN_CTM)
    );
}

/// objlib-24: a transition with no participating row upgrades nothing. Its constructor refuses
/// it, and so does the review, on either domain — which still hands the (inert) inventory on,
/// which no row check reads.
#[tokio::test]
async fn an_empty_proxy_upgrade_transition_upgrades_nothing() {
    for (domain, slots, expected) in [
        (
            PROXY_UPGRADE_DOMAIN_CORE,
            L1_ECOSYSTEM_CONTRACTS.len(),
            Inventory::Ecosystem,
        ),
        (
            PROXY_UPGRADE_DOMAIN_CTM,
            CTM_CONTRACTS.len(),
            Inventory::CtmDomain,
        ),
    ] {
        let empty = ProxyUpgradeTransitionManifest {
            domain,
            proxyUpgrades: vec![inert(); slots],
        };
        let (rows, result, reviewed, address) = verify_object(&empty, expected).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("upgrades nothing"));
        assert_eq!(rows.map(|rows| rows.len()), Some(slots));
        assert!(
            reviewed.contains_key(&address),
            "its construction still verifies"
        );
    }
}

// ───────────────────────── the release's own validate() ─────────────────────────

const RELEASE: Address = Address::repeat_byte(0x4E);

/// `validate()` as the mocked node answers it: success, or a revert carrying `revert` (a
/// response with no `data` field for an empty one, as some nodes send it).
async fn validate_outcome(revert: Option<Bytes>) -> Result<(), alloy::contract::Error> {
    let asserter = Asserter::new();
    match revert {
        None => asserter.push_success(&Bytes::new()),
        Some(data) if data.is_empty() => asserter.push_failure(
            serde_json::from_value(serde_json::json!({
                "code": 3,
                "message": "execution reverted",
            }))
            .unwrap(),
        ),
        Some(data) => asserter.push_failure(
            serde_json::from_value(serde_json::json!({
                "code": 3,
                "message": "execution reverted",
                "data": data,
            }))
            .unwrap(),
        ),
    }
    let provider = ProviderBuilder::new().connect_mocked_client(asserter);
    CTMReleaseView::new(RELEASE, &provider)
        .validate()
        .call()
        .await
        .map(|_| ())
}

async fn judge_validate(revert: Option<Bytes>) -> VerificationResult {
    let mut result = VerificationResult::default();
    judge_release_validity(
        &mut result,
        "the release",
        RELEASE,
        validate_outcome(revert).await,
    );
    result
}

/// objlib-16/13: the arriving release's `validate()` is called before the vote. A passing one
/// is clean; each revert it can raise is an error naming what it found.
#[tokio::test]
async fn the_arriving_releases_validate_is_called_before_the_vote() {
    use super::super::views::CTMReleaseView::{
        RegistryDuplicateSelector, RegistryEmptySelectors, RegistryTargetHasNoCode,
    };
    use alloy::sol_types::SolError;

    let result = judge_validate(None).await;
    assert_eq!((result.errors, result.warnings), (0, 0));

    let facet = Address::repeat_byte(0xFA);
    for (revert, needle) in [
        (
            RegistryTargetHasNoCode { target: facet }.abi_encode(),
            "RegistryTargetHasNoCode",
        ),
        (
            RegistryEmptySelectors { facet }.abi_encode(),
            "RegistryEmptySelectors",
        ),
        (
            RegistryDuplicateSelector {
                selector: [0x12, 0x34, 0x56, 0x78].into(),
            }
            .abi_encode(),
            "RegistryDuplicateSelector(0x12345678)",
        ),
        (Vec::new(), "a facet does not answer `selectors()`"),
        (vec![0xde, 0xad, 0xbe, 0xef], "reverts with 0xdeadbeef"),
    ] {
        let result = judge_validate(Some(Bytes::from(revert))).await;
        assert_eq!(result.errors, 1, "{needle}");
        assert!(result.has_error(needle), "{:?}", result.error_messages);
        assert!(result.has_error("fails its own `validate()`"));
    }

    // The same empty revert, sent as `data: "0x"`.
    let asserter = Asserter::new();
    asserter.push_failure(
        serde_json::from_value(serde_json::json!({
            "code": 3,
            "message": "execution reverted",
            "data": "0x",
        }))
        .unwrap(),
    );
    let provider = ProviderBuilder::new().connect_mocked_client(asserter);
    let outcome = CTMReleaseView::new(RELEASE, &provider)
        .validate()
        .call()
        .await
        .map(|_| ());
    let mut result = VerificationResult::default();
    judge_release_validity(&mut result, "the release", RELEASE, outcome);
    assert!(result.has_error("does not answer `selectors()`"));
}

// ───────────────────────── readiness ─────────────────────────

/// boot-42: the publication check reads the object's `l2Plan()` against the CTM's supplier and
/// names the call that would refuse an unpublished dependency — for the bootstrap, the
/// migration's `validate()` rather than a transition commit.
#[tokio::test]
async fn an_unpublished_dependency_names_the_call_that_refuses_it() {
    use super::super::views::{L2UpgradePlan, UniversalContractUpgradeInfo};
    const SUPPLIER: Address = Address::repeat_byte(0x5B);
    const MIGRATION: Address = Address::repeat_byte(0x3B);
    let plan = L2UpgradePlan {
        deployments: Vec::<UniversalContractUpgradeInfo>::new(),
        delegateTo: Address::ZERO,
        delegateComposer: Address::ZERO,
        factoryDepHashes: vec![U256::from(1), U256::from(2)],
    };
    let asserter = Asserter::new();
    asserter.push_success(&Bytes::from(SUPPLIER.abi_encode()));
    asserter.push_success(&Bytes::from(plan.abi_encode()));
    asserter.push_success(&Bytes::from(U256::from(17).abi_encode()));
    asserter.push_success(&Bytes::from(U256::ZERO.abi_encode()));
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    verify_bytecodes_published(
        &provider,
        &mut result,
        &CtmView::new(CTM, &provider),
        Publication {
            object: MIGRATION,
            label: "the bootstrap migration",
            required_by: "`RegistryBootstrapMigration.validate()` (run by `migrate()`)",
        },
    )
    .await
    .unwrap();
    assert!(asserter.read_q().is_empty());
    assert_eq!(result.errors, 1, "{:?}", result.error_messages);
    assert!(
        result.has_error("`RegistryBootstrapMigration.validate()` (run by `migrate()`) refuses it")
    );
}

// ───────────────────────── the whole path ─────────────────────────

/// objlib-25: `verify` itself refuses a package with no leg, before reading anything.
#[tokio::test]
async fn an_upgrade_with_no_leg_fails() {
    let asserter = Asserter::new();
    let provider = ProviderBuilder::new().connect_mocked_client(asserter);
    let mut result = VerificationResult::default();
    verify(
        &provider,
        &reviewed_build(),
        &unread_genesis(),
        &package(Vec::new(), Vec::new()),
        Some(GOVERNANCE),
        &[SALT],
        &ReviewedEnv::default(),
        &mut result,
    )
    .await
    .unwrap();
    assert_eq!(result.errors, 1);
    assert!(result.has_error("carries no executor leg"));
}

fn unread_genesis() -> ReviewedGenesis {
    use super::super::genesis::ExpectedForceDeployments;
    ReviewedGenesis {
        genesis_root: Ok(B256::ZERO),
        image: Err("not read".to_string()),
        force_deployments_data: None,
        force_deployments: ExpectedForceDeployments::unread(B256::ZERO),
    }
}

const GOVERNANCE: Address = Address::repeat_byte(0x60);

/// objlib-25: a package whose every leg applies an empty object is a no-op bundle. Each leg
/// is reported on the real path; the executors are left without records, which is reported
/// too but is not what this drives.
#[tokio::test]
async fn a_package_whose_every_leg_is_empty_fails() {
    let core = ProxyUpgradeTransitionManifest {
        domain: PROXY_UPGRADE_DOMAIN_CORE,
        proxyUpgrades: vec![inert(); L1_ECOSYSTEM_CONTRACTS.len()],
    };
    let infrastructure = ProxyUpgradeTransitionManifest {
        domain: PROXY_UPGRADE_DOMAIN_CTM,
        proxyUpgrades: vec![inert(); CTM_CONTRACTS.len()],
    };
    let at = |manifest: &ProxyUpgradeTransitionManifest| {
        canonical_create2_address(SALT, &transition_code(), &manifest.abi_encode())
    };
    let package = package(
        vec![
            leg_call(LegKind::Core, CORE_EXECUTOR, at(&core)),
            leg_call(LegKind::Infrastructure, CTM_EXECUTOR, at(&infrastructure)),
        ],
        Vec::new(),
    );

    let asserter = Asserter::new();
    let address = |a: Address| Bytes::from(a.abi_encode());
    for manifest in [&core, &infrastructure] {
        asserter.push_success(&Bytes::from_static(TRANSITION_RUNTIME));
        asserter.push_success(&Bytes::from(manifest.abi_encode()));
    }
    for answer in [
        Bytes::from_static(&[0x60]), // the core executor's code
        address(ECO_ADMIN),          // its PROXY_ADMIN
        Bytes::from_static(&[0x60]), // the CTM executor's code
        address(CTM),                // its CHAIN_TYPE_MANAGER
        address(CTM_ADMIN),          // its CTM_PROXY_ADMIN
        address(GOVERNANCE),         // the core executor's owner
        address(Address::ZERO),      // its pending owner
        address(GOVERNANCE),         // the CTM executor's owner
        address(Address::ZERO),      // its pending owner
        address(CTM_EXECUTOR),       // the CTM's owner
        address(CTM_EXECUTOR),       // the CTM-domain ProxyAdmin's owner
        address(Address::ZERO),      // the CTM's pending owner
        address(CORE_EXECUTOR),      // the ecosystem ProxyAdmin's owner
    ] {
        asserter.push_success(&answer);
    }
    let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
    let mut result = VerificationResult::default();
    verify(
        &provider,
        &reviewed_build(),
        &unread_genesis(),
        &package,
        Some(GOVERNANCE),
        &[SALT],
        &ReviewedEnv::default(),
        &mut result,
    )
    .await
    .unwrap();
    assert!(asserter.read_q().is_empty(), "every answer was read");
    let empty_legs = result
        .error_messages
        .iter()
        .filter(|e| e.contains("upgrades nothing"))
        .count();
    assert_eq!(empty_legs, 2, "{:?}", result.error_messages);
    assert!(result.ensure_success().is_err());
}

/// Exercise the real upgrade verifier, not `verify_shell_kept` directly: removing its shell
/// call must lose the extra error for a logic change. RPC mocks isolate this wiring from
/// unrelated provenance/genesis checks; those findings are identical in both runs.
#[tokio::test]
async fn upgrade_verification_rejects_an_incompatible_system_proxy_shell() {
    use super::super::shell_path_tests::{
        ShellPathFixture, CTM_EXECUTOR as FIXTURE_CTM_EXECUTOR, GOVERNANCE,
        TRANSITION as FIXTURE_TRANSITION,
    };

    let mut outcomes = Vec::new();
    for change_logic in [false, true] {
        let fixture = ShellPathFixture::new(change_logic);
        fixture.upgrade_reads();
        let provider = ProviderBuilder::new().connect_mocked_client(fixture.asserter.clone());
        let mut package = package(
            vec![leg_call(
                LegKind::Transition,
                FIXTURE_CTM_EXECUTOR,
                FIXTURE_TRANSITION,
            )],
            Vec::new(),
        );
        package.reported_ctm_executor = Some(FIXTURE_CTM_EXECUTOR);
        package.reported_ctm = None;
        package.reported_ctm_proxy_admin = None;
        let mut result = VerificationResult::default();
        verify(
            &provider,
            &fixture.build,
            &fixture.genesis,
            &package,
            Some(GOVERNANCE),
            &[],
            &ReviewedEnv::default(),
            &mut result,
        )
        .await
        .unwrap();
        outcomes.push((result, fixture.asserter.read_q().is_empty()));
    }
    assert_eq!(
        outcomes[1].0.errors,
        outcomes[0].0.errors + 1,
        "the real upgrade path must report the shell logic change as one additional error"
    );
    assert_eq!(outcomes[1].0.warnings, outcomes[0].0.warnings);
    assert!(outcomes[1].0.ensure_success().is_err());
    assert!(
        outcomes.iter().all(|(_, consumed)| *consumed),
        "both controls must reach the shell check"
    );
}

// ─────────────────── the rows' construction, through the whole path ───────────────────
//
// `verify` must hold each implementation a row installs to its construction record, with the
// members' arguments against the reviewed Bridgehub that the package's CTM and
// `bridgehub_proxy_addr` must agree with. The transport is mocked to isolate that wiring: the
// executors carry no records and are unverifiable in every run alike, so each run differs from
// its control by exactly the finding it drives.

use super::super::construction::DETERMINISTIC_CREATE2_FACTORY;
use crate::common::forge::scripts::member_deployments::{
    MemberDeploymentRecord, MemberDeployments,
};

const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
const ROW_PROXY: Address = Address::repeat_byte(0x9C);
const OLD_IMPL: Address = Address::repeat_byte(0x01);
const ROW_RUNTIME: &[u8] = b"the reviewed runtime of the row's contract";

/// A participating row of `contract`, built over `bridgehub` (its only constructor argument),
/// in `slot` of a `domain` inventory of `slots` slots; with the package calling it through
/// `executor` as `kind`, and the build holding `contract` and the transition object.
struct RowFixture {
    package: UpgradePackage,
    build: ReviewedBuild,
    records: MemberDeployments,
    manifest: ProxyUpgradeTransitionManifest,
}

impl RowFixture {
    fn new(
        kind: LegKind,
        executor: Address,
        (domain, slots, slot): (u8, usize, usize),
        (contract, parameter): (&'static str, &'static str),
    ) -> Self {
        let creation = format!("the creation code of {contract}").into_bytes();
        let args = BRIDGEHUB.abi_encode();
        let implementation = canonical_create2_address(SALT, &creation, &args);
        let mut rows = vec![inert(); slots];
        rows[slot] = ProxyUpgradeRow {
            proxy: ROW_PROXY,
            expectedOldImpl: OLD_IMPL,
            implNew: implementation,
            callInitializeUpgrade: false,
        };
        let manifest = ProxyUpgradeTransitionManifest {
            domain,
            proxyUpgrades: rows,
        };
        let object = canonical_create2_address(SALT, &transition_code(), &manifest.abi_encode());
        let build = ReviewedBuild::from_artifacts(
            CodeIdentity::empty()
                .with_contract("l1-contracts/ProxyUpgradeTransition", TRANSITION_RUNTIME),
            vec![
                (
                    "ProxyUpgradeTransition.sol",
                    "ProxyUpgradeTransition",
                    transition_code(),
                    TRANSITION_RUNTIME.to_vec(),
                    Vec::new(),
                ),
                (
                    "Row.sol",
                    contract,
                    creation.clone(),
                    ROW_RUNTIME.to_vec(),
                    Vec::new(),
                ),
            ],
        )
        .with_constructor(contract, &[(parameter, "address")]);
        let records = [(
            implementation,
            MemberDeploymentRecord {
                contract: contract.to_string(),
                create2_factory: DETERMINISTIC_CREATE2_FACTORY,
                create2_salt: SALT,
                constructor_args: Bytes::from(args),
            },
        )]
        .into_iter()
        .collect();
        Self {
            package: package(vec![leg_call(kind, executor, object)], Vec::new()),
            build,
            records,
            manifest,
        }
    }

    /// Runs `verify` over `answers` with or without the row's record, every answer read.
    async fn verify(&mut self, recorded: bool, answers: &[Bytes]) -> VerificationResult {
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(TRANSITION_RUNTIME));
        asserter.push_success(&Bytes::from(self.manifest.abi_encode()));
        for answer in answers {
            asserter.push_success(answer);
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        self.package.member_records = if recorded {
            self.records.clone()
        } else {
            MemberDeployments::new()
        };
        let mut result = VerificationResult::default();
        verify(
            &provider,
            &self.build,
            &unread_genesis(),
            &self.package,
            Some(GOVERNANCE),
            &[SALT],
            &ReviewedEnv::for_test(None, Some(BRIDGEHUB)),
            &mut result,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every answer was read");
        result
    }
}

fn word(address: Address) -> Bytes {
    Bytes::from(address.abi_encode())
}

/// A CTM-domain row: its `ValidatorTimelock` implementation is held to its record, and its
/// `_bridgehubAddr` to the reviewed Bridgehub, which the package's CTM must answer too.
#[tokio::test]
async fn a_ctm_domain_rows_implementation_is_held_to_its_record_on_the_upgrade_path() {
    let mut fixture = RowFixture::new(
        LegKind::Infrastructure,
        CTM_EXECUTOR,
        (PROXY_UPGRADE_DOMAIN_CTM, CTM_CONTRACTS.len(), 6),
        ("ValidatorTimelock", "_bridgehubAddr"),
    );
    assert_eq!(CTM_CONTRACTS[6], "ValidatorTimelock");
    let answers = |ctm_bridgehub: Option<Address>| {
        let mut answers = vec![
            Bytes::from_static(&[0x60]), // the CTM executor's code
            word(CTM),                   // its CHAIN_TYPE_MANAGER
            word(CTM_ADMIN),             // its CTM_PROXY_ADMIN
            word(GOVERNANCE),            // the CTM executor's owner
            word(Address::ZERO),         // its pending owner
            word(CTM_EXECUTOR),          // the CTM's owner
            word(CTM_EXECUTOR),          // the CTM-domain ProxyAdmin's owner
            word(Address::ZERO),         // the CTM's pending owner
            word(ROW_PROXY),             // the CTM's validatorTimelockPostV29()
            word(OLD_IMPL),              // the row's live implementation
            Bytes::from_static(ROW_RUNTIME),
        ];
        // The package's CTM's BRIDGE_HUB(), read once the record is.
        answers.extend(ctm_bridgehub.map(word));
        answers
    };
    let control = fixture.verify(true, &answers(Some(BRIDGEHUB))).await;
    assert!(
        !control.has_error("ValidatorTimelock"),
        "{:?}",
        control.error_messages
    );

    let unrecorded = fixture.verify(false, &answers(None)).await;
    assert_eq!(unrecorded.errors, control.errors + 1);
    assert!(unrecorded.has_error("a row installs only an implementation its prepare deployed"));

    let elsewhere = fixture.verify(true, &answers(Some(STRANGER))).await;
    assert_eq!(elsewhere.errors, control.errors + 1);
    assert!(elsewhere.has_error(&format!(
        "the package's CTM {CTM} answers BRIDGE_HUB() {STRANGER}, not env test's \
             bridgehub_proxy_addr {BRIDGEHUB}"
    )));
}

/// An ecosystem row of a core-only package: its `ChainRegistrationSender` implementation is
/// held to its record, and its `_bridgehub` to the reviewed Bridgehub, which the package's
/// `bridgehub_proxy_addr` must name too.
#[tokio::test]
async fn an_ecosystem_rows_implementation_is_held_to_its_record_on_the_upgrade_path() {
    let slot = L1_ECOSYSTEM_CONTRACTS.len() - 1;
    assert_eq!(L1_ECOSYSTEM_CONTRACTS[slot], "ChainRegistrationSender");
    let mut fixture = RowFixture::new(
        LegKind::Core,
        CORE_EXECUTOR,
        (
            PROXY_UPGRADE_DOMAIN_CORE,
            L1_ECOSYSTEM_CONTRACTS.len(),
            slot,
        ),
        ("ChainRegistrationSender", "_bridgehub"),
    );
    fixture.package.reported_ctm_executor = None;
    fixture.package.reported_ctm = None;
    fixture.package.reported_ctm_proxy_admin = None;
    fixture.package.reported_singletons.bridgehub = Some(BRIDGEHUB);
    let answers = [
        Bytes::from_static(&[0x60]), // the core executor's code
        word(ECO_ADMIN),             // its PROXY_ADMIN
        word(GOVERNANCE),            // the core executor's owner
        word(Address::ZERO),         // its pending owner
        word(CORE_EXECUTOR),         // the ecosystem ProxyAdmin's owner
        word(ROW_PROXY),             // the Bridgehub's chainRegistrationSender()
        word(OLD_IMPL),              // the row's live implementation
        Bytes::from_static(ROW_RUNTIME),
    ];
    let control = fixture.verify(true, &answers).await;
    assert!(
        !control.has_error("ChainRegistrationSender"),
        "{:?}",
        control.error_messages
    );

    let unrecorded = fixture.verify(false, &answers).await;
    assert_eq!(unrecorded.errors, control.errors + 1);
    assert!(unrecorded.has_error("a row installs only an implementation its prepare deployed"));

    fixture.package.reported_singletons.bridgehub = Some(STRANGER);
    let elsewhere = fixture.verify(true, &answers).await;
    assert_eq!(elsewhere.errors, control.errors + 1);
    assert!(elsewhere.has_error(&format!(
        "the package's bridgehub_proxy_addr {STRANGER} is not env test's bridgehub_proxy_addr \
             {BRIDGEHUB}"
    )));
}
