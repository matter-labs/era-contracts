use super::*;
use alloy::primitives::U256;

fn call(target: Address, data: Vec<u8>) -> GovernanceCall {
    GovernanceCall {
        target,
        value: U256::ZERO,
        data,
    }
}

#[test]
fn migrate_selector_matches_the_solidity_signature() {
    // Guards the hardcoded constant against a signature change.
    let computed = alloy::primitives::keccak256(b"migrate()");
    assert_eq!(&computed[..4], &MIGRATE_SELECTOR);
}

#[test]
fn transfer_ownership_selector_matches_the_solidity_signature() {
    let computed = alloy::primitives::keccak256(b"transferOwnership(address)");
    assert_eq!(&computed[..4], &TRANSFER_OWNERSHIP_SELECTOR);
}

/// The three entrypoints a leg is recognized by must be the executors' real ones, so a
/// signature change is caught here rather than by a package whose legs silently stop being
/// recognized. Transcribed (from the compiled artifacts' `methodIdentifiers`) as well as
/// derived, so the `sol!` mirror cannot drift with them.
#[test]
fn the_leg_selectors_are_the_executors() {
    for (kind, signature, transcribed) in [
        (
            LegKind::Core,
            "applyL1Upgrade(address)",
            [0x60, 0x93, 0xa2, 0x59],
        ),
        (
            LegKind::Infrastructure,
            "applyInfrastructureUpgrade(address)",
            [0x68, 0xe9, 0x89, 0x78],
        ),
        (
            LegKind::Transition,
            "applyCTMUpgrade(address)",
            [0x7b, 0x1b, 0x71, 0x6a],
        ),
    ] {
        assert_eq!(kind.selector(), transcribed, "{signature}");
        assert_eq!(
            &alloy::primitives::keccak256(signature.as_bytes())[..4],
            &transcribed,
            "{signature}"
        );
        let encoded = kind.encode(Address::repeat_byte(0x0b));
        assert_eq!(encoded.len(), 4 + 32);
        assert_eq!(kind.decode(&encoded), Some(Address::repeat_byte(0x0b)));
    }
}

#[test]
fn the_canonical_order_is_core_infrastructure_transition() {
    assert_eq!(
        LegKind::CANONICAL_ORDER,
        [LegKind::Core, LegKind::Infrastructure, LegKind::Transition]
    );
    assert!(LegKind::Core < LegKind::Infrastructure);
    assert!(LegKind::Infrastructure < LegKind::Transition);
}

#[test]
fn recovers_the_migration_from_the_bundle() {
    let migration = Address::repeat_byte(0xAB);
    let bundle = vec![
        call(
            Address::repeat_byte(0x11),
            TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
        ),
        call(migration, MIGRATE_SELECTOR.to_vec()),
    ];
    assert_eq!(sole_migrate_target(&bundle).unwrap(), migration);
}

#[test]
fn rejects_a_package_with_no_migrate_call() {
    let bundle = vec![call(
        Address::repeat_byte(0x11),
        vec![0xde, 0xad, 0xbe, 0xef],
    )];
    let err = sole_migrate_target(&bundle).unwrap_err().to_string();
    assert!(err.contains("no `migrate()` call"), "{err}");
}

#[test]
fn rejects_a_package_driving_two_edges() {
    let bundle = vec![
        call(Address::repeat_byte(0xAA), MIGRATE_SELECTOR.to_vec()),
        call(Address::repeat_byte(0xBB), MIGRATE_SELECTOR.to_vec()),
    ];
    let err = sole_migrate_target(&bundle).unwrap_err().to_string();
    assert!(err.contains("exactly one edge"), "{err}");
}

// ───────────────────────── upgrade packages ─────────────────────────
//
// A merged prepare output in the exact shape `write_merged_ecosystem_toml` emits — the core
// and CTM prepares' summaries and the legs the merge derived from them, as real ABI-encoded
// `Call[]` hex — so the loader is driven through the same entry point production uses.

const CORE_EXECUTOR: Address = Address::repeat_byte(0xE0);
const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);
const CORE_TRANSITION: Address = Address::repeat_byte(0xEE);
const INFRASTRUCTURE: Address = Address::repeat_byte(0x1F);
const TRANSITION: Address = Address::repeat_byte(0xCC);
const RELEASE: Address = Address::repeat_byte(0xC1);
const CTM_PROXY: Address = Address::repeat_byte(0xF1);
const CTM_ADMIN: Address = Address::repeat_byte(0xF2);
const ECO_ADMIN: Address = Address::repeat_byte(0xE2);
const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
const STRANGER: Address = Address::repeat_byte(0x99);

fn leg(kind: LegKind, executor: Address, object: Address) -> GovernanceCall {
    call(executor, kind.encode(object))
}

fn core_leg() -> GovernanceCall {
    leg(LegKind::Core, CORE_EXECUTOR, CORE_TRANSITION)
}

fn infrastructure_leg() -> GovernanceCall {
    leg(LegKind::Infrastructure, CTM_EXECUTOR, INFRASTRUCTURE)
}

fn transition_leg() -> GovernanceCall {
    leg(LegKind::Transition, CTM_EXECUTOR, TRANSITION)
}

/// The prepares' summaries of what they deployed: zero for an object a prepare did not deploy.
#[derive(Clone)]
struct Summary {
    core_transition: Address,
    infrastructure: Address,
    transition: Address,
    bootstrap_migration: Address,
    ctm_section: bool,
}

impl Summary {
    fn all() -> Self {
        Self {
            core_transition: CORE_TRANSITION,
            infrastructure: INFRASTRUCTURE,
            transition: TRANSITION,
            bootstrap_migration: Address::ZERO,
            ctm_section: true,
        }
    }

    fn of(core: bool, infrastructure: bool, transition: bool) -> Self {
        let pick = |on: bool, object: Address| if on { object } else { Address::ZERO };
        Self {
            core_transition: pick(core, CORE_TRANSITION),
            infrastructure: pick(infrastructure, INFRASTRUCTURE),
            transition: pick(transition, TRANSITION),
            ..Self::all()
        }
    }

    fn toml(&self, calls: &[GovernanceCall]) -> String {
        let mut body = format!(
            "[core]\n\
                 create2_factory_salt = \"{}\"\n\
                 [core.registry]\n\
                 core_transition_addr = \"{}\"\n\
                 core_upgrade_executor_addr = \"{CORE_EXECUTOR}\"\n\
                 [core.upgrade_addresses.shared]\n\
                 transparent_proxy_admin = \"{ECO_ADMIN}\"\n\
                 [core.upgrade_addresses.bridgehub]\n\
                 bridgehub_proxy_addr = \"{BRIDGEHUB}\"\n",
            B256::repeat_byte(0x5A),
            self.core_transition,
        );
        if self.ctm_section {
            body.push_str(&format!(
                "[ctms.zksync_os]\n\
                     create2_factory_salt = \"{}\"\n\
                     [ctms.zksync_os.registry]\n\
                     ctm_transition_addr = \"{}\"\n\
                     ctm_infrastructure_transition_addr = \"{}\"\n\
                     ctm_release_addr = \"{RELEASE}\"\n\
                     bootstrap_migration_addr = \"{}\"\n\
                     ctm_upgrade_executor_addr = \"{CTM_EXECUTOR}\"\n\
                     [ctms.zksync_os.state_transition]\n\
                     chain_type_manager_proxy = \"{CTM_PROXY}\"\n\
                     [ctms.zksync_os.deployed_addresses]\n\
                     transparent_proxy_admin = \"{CTM_ADMIN}\"\n\
                     [ctms.zksync_os.contracts_config]\n\
                     force_deployments_data = \"0xf0f1f2\"\n",
                B256::repeat_byte(0x6B),
                self.transition,
                self.infrastructure,
                self.bootstrap_migration,
            ));
        }
        body.push_str(&format!(
            "[governance_calls]\ncalls = \"0x{}\"\n",
            alloy::hex::encode(crate::common::governance_calls::encode_calls(calls))
        ));
        body
    }
}

fn load_str(body: &str) -> anyhow::Result<RegistryPackage> {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ecosystem.toml");
    std::fs::write(&path, body).unwrap();
    RegistryPackage::load(&path)
}

fn load_upgrade(summary: &Summary, calls: &[GovernanceCall]) -> UpgradePackage {
    match load_str(&summary.toml(calls)).expect("the package must load") {
        RegistryPackage::Upgrade(package) => package,
        other => panic!("expected an upgrade package, got {other:?}"),
    }
}

fn refusal(summary: &Summary, calls: &[GovernanceCall]) -> String {
    format!(
        "{:#}",
        load_str(&summary.toml(calls)).expect_err("the package must be refused")
    )
}

/// The classification is the calldata: executor legs make an upgrade, and every leg is
/// recovered from the call governance signs — with its executor and object — and reconciled
/// with the summary that names it.
#[test]
fn an_upgrade_package_loads_its_legs_from_the_calldata() {
    let package = load_upgrade(
        &Summary::all(),
        &[core_leg(), infrastructure_leg(), transition_leg()],
    );
    assert_eq!(
        package.legs,
        vec![
            RecoveredLeg {
                kind: LegKind::Core,
                index: 0,
                executor: CORE_EXECUTOR,
                object: CORE_TRANSITION,
            },
            RecoveredLeg {
                kind: LegKind::Infrastructure,
                index: 1,
                executor: CTM_EXECUTOR,
                object: INFRASTRUCTURE,
            },
            RecoveredLeg {
                kind: LegKind::Transition,
                index: 2,
                executor: CTM_EXECUTOR,
                object: TRANSITION,
            },
        ]
    );
    assert_eq!(package.ctm_key.as_deref(), Some("zksync_os"));
    assert_eq!(package.reported_ctm, Some(CTM_PROXY));
    assert_eq!(package.reported_ctm_proxy_admin, Some(CTM_ADMIN));
    assert_eq!(package.reported_singletons.bridgehub, Some(BRIDGEHUB));
    assert_eq!(package.lifecycle.core_executor, Some(CORE_EXECUTOR));
    assert_eq!(package.lifecycle.core_proxy_admin, Some(ECO_ADMIN));
    assert_eq!(
        package.force_deployments_data,
        Some(Bytes::from_static(&[0xf0, 0xf1, 0xf2]))
    );
    assert_eq!(
        package.create2_salts,
        vec![B256::repeat_byte(0x5A), B256::repeat_byte(0x6B)]
    );
}

/// Each leg alone is an upgrade of its own — the subsequence of the canonical run.
#[test]
fn each_leg_alone_loads_as_an_upgrade() {
    for (summary, call, kind) in [
        (Summary::of(true, false, false), core_leg(), LegKind::Core),
        (
            Summary::of(false, true, false),
            infrastructure_leg(),
            LegKind::Infrastructure,
        ),
        (
            Summary::of(false, false, true),
            transition_leg(),
            LegKind::Transition,
        ),
    ] {
        let package = load_upgrade(&summary, &[call]);
        assert_eq!(package.legs.len(), 1);
        assert_eq!(package.legs[0].kind, kind);
    }
}

/// A core-only upgrade needs no CTM prepare: with no `[ctms]` section at all it still loads,
/// and reads its CTM inputs as absent.
#[test]
fn a_core_only_package_needs_no_ctm_section() {
    let summary = Summary {
        ctm_section: false,
        ..Summary::of(true, false, false)
    };
    let package = load_upgrade(&summary, &[core_leg()]);
    assert_eq!(package.ctm_key, None);
    assert_eq!(package.reported_ctm, None);
    assert_eq!(package.force_deployments_data, None);
    assert_eq!(package.create2_salts, vec![B256::repeat_byte(0x5A)]);
}

/// A CTM leg without the CTM section cannot be held against the reviewed CTM at all.
#[test]
fn a_ctm_leg_requires_the_ctm_section() {
    let summary = Summary {
        ctm_section: false,
        ..Summary::of(false, false, true)
    };
    let err = refusal(&summary, &[transition_leg()]);
    assert!(err.contains("[ctms] missing from the package"), "{err}");
}

/// A package that is neither kind must not be verified as the nearest match.
#[test]
fn a_package_that_is_neither_kind_is_refused() {
    let err = refusal(&Summary::of(false, false, false), &[]);
    assert!(err.contains("neither kind of package"), "{err}");
    let err = refusal(
        &Summary::of(false, false, false),
        &[call(STRANGER, vec![0xde, 0xad, 0xbe, 0xef])],
    );
    assert!(err.contains("neither kind of package"), "{err}");
}

/// The post-replay check asks whether a governance TOML is a registry package at all: one
/// that is none of the three kinds is `None` there (not refused), while a registry package
/// still loads — or is refused — exactly as `load` would.
#[test]
fn only_a_bundle_of_none_of_the_kinds_is_not_a_registry_package() {
    let load_if = |summary: &Summary, calls: &[GovernanceCall]| {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ecosystem.toml");
        std::fs::write(&path, summary.toml(calls)).unwrap();
        RegistryPackage::load_if_registry(&path)
    };
    let none = Summary::of(false, false, false);
    assert!(load_if(&none, &[]).unwrap().is_none());
    assert!(
        load_if(&none, &[call(STRANGER, vec![0xde, 0xad, 0xbe, 0xef])])
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        load_if(
            &Summary::all(),
            &[core_leg(), infrastructure_leg(), transition_leg()]
        ),
        Ok(Some(RegistryPackage::Upgrade(_)))
    ));
    let err = load_if(&Summary::all(), &[core_leg()]).expect_err("a missing leg is refused");
    assert!(format!("{err:#}").contains("missing leg"), "{err:#}");
}

/// A pre-collapse package — per-stage keys instead of the one `calls` — is refused rather
/// than read with its calls dropped.
#[test]
fn a_package_with_per_stage_keys_is_refused() {
    let body = Summary::all()
        .toml(&[])
        .replace("calls = \"0x", "stage1_calls = \"0x\"\nstage0_calls = \"0x");
    let err = format!("{:#}", load_str(&body).unwrap_err());
    assert!(err.contains("exactly one key"), "{err}");
}

/// Q5: the summary names an object the bundle never applies — a reviewed object that would be
/// left unapplied.
#[test]
fn a_missing_leg_is_refused() {
    let err = refusal(&Summary::all(), &[core_leg(), transition_leg()]);
    assert!(err.contains("missing leg"), "{err}");
    assert!(err.contains("ctm_infrastructure_transition_addr"), "{err}");
}

/// The other direction: a leg no summary accounts for.
#[test]
fn a_leg_without_its_summary_is_refused() {
    let err = refusal(
        &Summary::of(true, false, false),
        &[core_leg(), transition_leg()],
    );
    assert!(err.contains("reports no ctm_transition_addr"), "{err}");
}

/// Q5: the bundle applies another object than the one the summary names.
#[test]
fn a_substituted_object_is_refused() {
    let err = refusal(
        &Summary::of(false, false, true),
        &[leg(LegKind::Transition, CTM_EXECUTOR, STRANGER)],
    );
    assert!(err.contains("substituted object"), "{err}");
}

/// The right object sent to another executor than the summary names — including a core leg
/// sent to the CTM domain's executor.
#[test]
fn a_substituted_executor_is_refused() {
    for bad in [
        leg(LegKind::Core, STRANGER, CORE_TRANSITION),
        leg(LegKind::Core, CTM_EXECUTOR, CORE_TRANSITION),
    ] {
        let err = refusal(&Summary::of(true, false, false), &[bad]);
        assert!(err.contains("substituted executor"), "{err}");
    }
    let err = refusal(
        &Summary::of(false, true, true),
        &[
            infrastructure_leg(),
            leg(LegKind::Transition, STRANGER, TRANSITION),
        ],
    );
    assert!(err.contains("substituted executor"), "{err}");
}

/// Q5: a leg twice — the second application is not a bundle the merge produces.
#[test]
fn a_duplicated_leg_is_refused() {
    let err = refusal(
        &Summary::of(false, false, true),
        &[transition_leg(), transition_leg()],
    );
    assert!(err.contains("duplicate leg"), "{err}");
}

/// The executor entrypoints are not payable, so a leg carrying value is not the derived call.
#[test]
fn a_leg_carrying_value_is_refused() {
    let mut paying = core_leg();
    paying.value = U256::from(1);
    let err = refusal(&Summary::of(true, false, false), &[paying]);
    assert!(err.contains("carries value"), "{err}");
}

/// A call with a leg's selector but not exactly its calldata is refused rather than read as
/// the nearest leg.
#[test]
fn malformed_leg_calldata_is_refused() {
    let mut trailing = core_leg();
    trailing.data.extend_from_slice(&[0u8; 32]);
    let err = refusal(&Summary::of(true, false, false), &[trailing]);
    assert!(err.contains("not exactly its calldata"), "{err}");

    let mut dirty = core_leg();
    dirty.data[4] = 0xff; // an address word with its high bytes set
    let err = refusal(&Summary::of(true, false, false), &[dirty]);
    assert!(err.contains("not exactly its calldata"), "{err}");
}

/// Q5: any call to an executor other than its legs — a `forward`, a nomination — is
/// authority the review never saw, and is refused whether or not the package declares it.
#[test]
fn an_unknown_selector_on_an_executor_is_refused() {
    let nomination = call(
        CTM_EXECUTOR,
        [
            TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
            STRANGER.into_word().to_vec(),
        ]
        .concat(),
    );
    let err = refusal(
        &Summary::of(false, false, true),
        &[transition_leg(), nomination],
    );
    assert!(err.contains("unknown selector on an executor"), "{err}");

    // The core executor is the ecosystem domain's, even when this upgrade has no core leg.
    let forward = call(
        CORE_EXECUTOR,
        CTMUpgradeExecutorView::forwardCall { _calls: Vec::new() }.abi_encode(),
    );
    let err = refusal(
        &Summary::of(false, false, true),
        &[forward, transition_leg()],
    );
    assert!(err.contains("unknown selector on an executor"), "{err}");
}

/// Q5 mixed kinds: CTM legs beside a bootstrap's `migrate()`.
#[test]
fn upgrade_legs_beside_a_migrate_are_refused() {
    let migration = Address::repeat_byte(0x55);
    let summary = Summary {
        bootstrap_migration: migration,
        ..Summary::of(true, false, false)
    };
    let err = refusal(
        &summary,
        &[
            core_leg(),
            transition_leg(),
            call(migration, MIGRATE_SELECTOR.to_vec()),
        ],
    );
    assert!(err.contains("mixed kinds"), "{err}");
}

/// The bootstrap's own sequence applies the core transition — that one leg is the edge's, not
/// an upgrade beside it, so the package loads as a bootstrap.
#[test]
fn the_bootstrap_sequences_core_leg_is_not_a_mixed_kind() {
    let migration = Address::repeat_byte(0x55);
    let summary = Summary {
        bootstrap_migration: migration,
        ..Summary::of(true, false, false)
    };
    let package =
        load_str(&summary.toml(&[core_leg(), call(migration, MIGRATE_SELECTOR.to_vec())])).unwrap();
    let RegistryPackage::Bootstrap(package) = package else {
        panic!("a migrate() bundle is a bootstrap");
    };
    assert_eq!(package.migration, migration);
    assert_eq!(package.core_transition, Some(CORE_TRANSITION));
}

/// A bootstrap's summary naming a CTM-domain object: nothing in the edge applies it.
#[test]
fn a_bootstrap_reporting_a_ctm_object_is_refused() {
    let migration = Address::repeat_byte(0x55);
    let summary = Summary {
        bootstrap_migration: migration,
        ..Summary::of(true, false, true)
    };
    let err = refusal(&summary, &[call(migration, MIGRATE_SELECTOR.to_vec())]);
    assert!(err.contains("missing leg"), "{err}");
    assert!(err.contains("bootstrap"), "{err}");
}

// ───────────────────────── a release the tool has never heard of ─────────────────────────
//
// `CTMUpgrade_v36 is DefaultCTMUpgrade {}` — an empty subclass. A v36 upgrade is an ORDINARY
// registry upgrade, so it must load through the general path with no v36 module, no v36
// branch and no v36 constant anywhere in this tree. The loader never learns a release name.

/// A release with no module of its own loads as an ordinary upgrade, and every summary field
/// the verifier holds the CTM executor's immutables against is picked up.
#[test]
fn a_release_with_no_module_of_its_own_loads_as_an_ordinary_upgrade() {
    let package = load_upgrade(&Summary::of(false, false, true), &[transition_leg()]);
    assert_eq!(package.reported_ctm_transition, Some(TRANSITION));
    assert_eq!(package.reported_ctm_executor, Some(CTM_EXECUTOR));
    assert_eq!(package.reported_ctm, Some(CTM_PROXY));
    assert_eq!(package.reported_ctm_proxy_admin, Some(CTM_ADMIN));
}

/// The zero `bootstrap_migration_addr` a post-bootstrap release carries must not divert it
/// into the bootstrap path.
#[test]
fn a_zero_bootstrap_field_does_not_divert_an_ordinary_release() {
    let body = Summary::of(false, false, true).toml(&[transition_leg()]);
    assert!(body.contains("bootstrap_migration_addr"));
    assert!(matches!(
        load_str(&body).unwrap(),
        RegistryPackage::Upgrade(_)
    ));
}

// ───────────────────────── transition replacements ─────────────────────────

use super::super::views::{BootstrapCall, CtmView};

const CTM: Address = Address::repeat_byte(0xC7);
const EXPECTED: Address = Address::repeat_byte(0x7A);
const REPLACEMENT: Address = Address::repeat_byte(0x7B);
const DEPARTURE: u64 = 0x23_0000_0000;

fn inner(target: Address, data: Vec<u8>) -> BootstrapCall {
    BootstrapCall {
        target,
        value: U256::ZERO,
        data: data.into(),
    }
}

fn replace_call() -> BootstrapCall {
    inner(
        CTM,
        CtmView::replaceUpgradeTransitionCall {
            _expectedTransition: EXPECTED,
            _replacement: REPLACEMENT,
        }
        .abi_encode(),
    )
}

fn deadline_call(version: u64, timestamp: u64) -> BootstrapCall {
    inner(
        CTM,
        CtmView::setProtocolVersionDeadlineCall {
            _protocolVersion: U256::from(version),
            _timestamp: U256::from(timestamp),
        }
        .abi_encode(),
    )
}

fn forward(calls: Vec<BootstrapCall>) -> GovernanceCall {
    call(
        CTM_EXECUTOR,
        CTMUpgradeExecutorView::forwardCall { _calls: calls }.abi_encode(),
    )
}

#[test]
fn recovers_a_replacement_from_its_forward() {
    let recovered = recover_replacement(&[forward(vec![replace_call()])])
        .unwrap()
        .expect("a forward of replaceUpgradeTransition is a replacement");
    assert_eq!(
        recovered,
        RecoveredReplacement {
            index: 0,
            executor: CTM_EXECUTOR,
            ctm: CTM,
            expected: EXPECTED,
            replacement: REPLACEMENT,
            deadline: None,
        }
    );
}

#[test]
fn recovers_the_deadline_call_riding_the_same_forward() {
    let recovered = recover_replacement(&[
        call(Address::repeat_byte(0x11), vec![0xde, 0xad, 0xbe, 0xef]),
        forward(vec![
            replace_call(),
            deadline_call(DEPARTURE, 1_900_000_000),
        ]),
    ])
    .unwrap()
    .unwrap();
    assert_eq!(recovered.index, 1);
    assert_eq!(
        recovered.deadline,
        Some(DeadlineChange {
            protocol_version: U256::from(DEPARTURE),
            timestamp: U256::from(1_900_000_000u64),
        })
    );
}

/// The bootstrap's notifier acceptance is a `forward` too; without a replace it is not a
/// replacement, and a package of only ordinary calls has none.
#[test]
fn a_forward_that_replaces_nothing_is_not_a_replacement() {
    let accept = inner(Address::repeat_byte(0x2A), vec![0x79, 0xba, 0x50, 0x97]);
    assert!(recover_replacement(&[forward(vec![accept])])
        .unwrap()
        .is_none());
    assert!(recover_replacement(&[]).unwrap().is_none());
}

/// Anything beside the replace and the optional deadline would ride a verified replacement
/// unverified, so it is refused outright.
#[test]
fn a_forward_carrying_anything_else_is_refused() {
    let nomination = inner(
        CTM,
        [
            TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
            Address::repeat_byte(0xBA).into_word().to_vec(),
        ]
        .concat(),
    );
    for calls in [
        vec![replace_call(), nomination.clone()],
        vec![nomination.clone(), replace_call()],
        vec![
            replace_call(),
            deadline_call(DEPARTURE, 1),
            deadline_call(DEPARTURE, 2),
        ],
    ] {
        let err = recover_replacement(&[forward(calls)])
            .unwrap_err()
            .to_string();
        assert!(err.contains("anything else in it is refused"), "{err}");
    }

    // Two targets in one forward.
    let mut elsewhere = deadline_call(DEPARTURE, 1);
    elsewhere.target = Address::repeat_byte(0xC8);
    let err = recover_replacement(&[forward(vec![replace_call(), elsewhere])])
        .unwrap_err()
        .to_string();
    assert!(err.contains("more than one target"), "{err}");

    // Value.
    let mut paying = forward(vec![replace_call()]);
    paying.value = U256::from(1);
    let err = recover_replacement(&[paying]).unwrap_err().to_string();
    assert!(err.contains("carries value"), "{err}");
}

#[test]
fn two_replacing_forwards_are_refused() {
    let err = recover_replacement(&[forward(vec![replace_call()]), forward(vec![replace_call()])])
        .unwrap_err()
        .to_string();
    assert!(err.contains("more than one `forward`"), "{err}");
}

/// The merged package a replacement prepare produces: no `migrate()`, no executor leg, the
/// forward in the bundle — classified as its own kind, with every summary field picked up.
fn replacement_body(replacement: &GovernanceCall, extra_registry: &str) -> String {
    format!(
        "[[external_actions]]\n\
             phase = \"governance\"\n\
             label = \"replace the committed transition departing {DEPARTURE}\"\n\
             authority = \"CTM executor owner (governance)\"\n\
             target = \"{CTM_EXECUTOR}\"\n\
             value = \"0\"\n\
             data = \"0x{}\"\n\
             [governance_calls]\n\
             calls = \"0x{}\"\n\
             [ctms.zksync_os.registry]\n\
             replaced_transition_addr = \"{EXPECTED}\"\n\
             replacement_transition_addr = \"{REPLACEMENT}\"\n\
             ctm_transition_addr = \"{REPLACEMENT}\"\n\
             ctm_infrastructure_transition_addr = \"0x0000000000000000000000000000000000000000\"\n\
             ctm_upgrade_executor_addr = \"{CTM_EXECUTOR}\"\n\
             {extra_registry}\
             [ctms.zksync_os.state_transition]\n\
             chain_type_manager_proxy = \"{CTM}\"\n\
             [ctms.zksync_os.contracts_config]\n\
             old_protocol_version = {DEPARTURE}\n\
             new_protocol_version = {}\n",
        alloy::hex::encode(&replacement.data),
        alloy::hex::encode(crate::common::governance_calls::encode_calls(
            std::slice::from_ref(replacement)
        )),
        DEPARTURE + 0x1_0000_0000,
    )
}

#[test]
fn a_replacement_package_loads_as_its_own_kind() {
    let replacement = forward(vec![replace_call(), deadline_call(DEPARTURE, 7)]);
    let RegistryPackage::Replacement(package) =
        load_str(&replacement_body(&replacement, "")).unwrap()
    else {
        panic!("a forwarded replaceUpgradeTransition must load as a replacement");
    };
    assert_eq!(package.forward.expected, EXPECTED);
    assert_eq!(package.forward.replacement, REPLACEMENT);
    assert_eq!(package.forward.executor, CTM_EXECUTOR);
    assert!(package.forward.deadline.is_some());
    assert_eq!(package.reported_replaced, Some(EXPECTED));
    assert_eq!(package.reported_replacement, Some(REPLACEMENT));
    assert_eq!(package.reported_ctm_executor, Some(CTM_EXECUTOR));
    assert_eq!(package.reported_ctm, Some(CTM));
    assert_eq!(package.reported_old_version, Some(U256::from(DEPARTURE)));
    assert_eq!(package.external_actions.len(), 1);
    assert!(package.external_actions[0].is_call(&replacement));
    assert!(package.executor_records.is_empty());
}

/// Q5 mixed kinds: an executor leg beside the replacing `forward`. The replacement's
/// `ctm_transition_addr` is the replacement, not a transition leg.
#[test]
fn upgrade_legs_beside_a_replacement_are_refused() {
    let replacement = forward(vec![replace_call()]);
    let body = replacement_body(&replacement, "").replace(
        &format!(
            "calls = \"0x{}\"",
            alloy::hex::encode(crate::common::governance_calls::encode_calls(
                std::slice::from_ref(&replacement)
            ))
        ),
        &format!(
            "calls = \"0x{}\"",
            alloy::hex::encode(crate::common::governance_calls::encode_calls(&[
                replacement.clone(),
                leg(LegKind::Transition, CTM_EXECUTOR, REPLACEMENT),
            ]))
        ),
    );
    let err = format!("{:#}", load_str(&body).unwrap_err());
    assert!(err.contains("mixed kinds"), "{err}");
    assert!(err.contains("carries no executor leg"), "{err}");
}

/// A bootstrap and a replacement in one bundle are two reviews, not one.
#[test]
fn a_migrate_beside_a_replacement_is_refused() {
    let replacement = forward(vec![replace_call()]);
    let migrate = call(Address::repeat_byte(0x55), MIGRATE_SELECTOR.to_vec());
    let body = replacement_body(&replacement, "").replace(
        &format!(
            "calls = \"0x{}\"",
            alloy::hex::encode(crate::common::governance_calls::encode_calls(
                std::slice::from_ref(&replacement)
            ))
        ),
        &format!(
            "calls = \"0x{}\"",
            alloy::hex::encode(crate::common::governance_calls::encode_calls(&[
                replacement.clone(),
                migrate,
            ]))
        ),
    );
    let err = format!("{:#}", load_str(&body).unwrap_err());
    assert!(err.contains("mixed kinds"), "{err}");
}

/// A replacement whose package also reports a core transition: the merge derives no leg for a
/// replacement, so the object would never be applied.
#[test]
fn a_core_transition_on_a_replacement_is_refused() {
    let replacement = forward(vec![replace_call()]);
    let body = format!(
        "{}[core.registry]\ncore_transition_addr = \"{CORE_TRANSITION}\"\n",
        replacement_body(&replacement, "")
    );
    let err = format!("{:#}", load_str(&body).unwrap_err());
    assert!(err.contains("missing leg"), "{err}");
    assert!(err.contains("core_transition_addr"), "{err}");
}
