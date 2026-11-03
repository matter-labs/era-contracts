use super::*;
use std::fs;

use alloy::hex;
use alloy::primitives::Address;

use crate::common::env_config::GovernanceKind;
use crate::common::external_actions::{ExternalAction, GOVERNANCE_PHASE};
use crate::common::governance_calls::GovernanceCallsTable;
use crate::upgrade_verification::registry::package::RegistryPackage;

/// A PUH-governed env is not by itself a reason to replace its governance set: only the
/// release's own declaration is. Every recurring preparation used to take the first for the
/// second.
#[test]
fn the_governance_redeploy_needs_both_a_puh_env_and_a_declaration() {
    assert!(!zk_governance_redeploy_decision(GovernanceKind::Puh, false).unwrap());
    assert!(!zk_governance_redeploy_decision(GovernanceKind::Legacy, false).unwrap());
    assert!(zk_governance_redeploy_decision(GovernanceKind::Puh, true).unwrap());

    let err = zk_governance_redeploy_decision(GovernanceKind::Legacy, true)
        .expect_err("declaring the redeploy on a legacy-governance env must be named, not skipped");
    assert!(err.to_string().contains("redeploy_zk_governance"), "{err}");
}
use crate::common::governance_calls::{encode_calls, GovernanceCall};

fn call(target: u8, data: &[u8]) -> GovernanceCall {
    GovernanceCall {
        target: Address::repeat_byte(target),
        value: alloy::primitives::U256::ZERO,
        data: data.to_vec(),
    }
}

fn bundle_hex(calls: &[GovernanceCall]) -> String {
    format!("0x{}", hex::encode(encode_calls(calls)))
}

fn gov(calls: &[GovernanceCall]) -> GovernanceCallsTable {
    GovernanceCallsTable {
        calls: bundle_hex(calls),
    }
}

#[test]
fn a_bundle_of_exactly_the_declared_actions_passes() {
    let emitted = [call(0x11, &[0xaa]), call(0x22, &[0xbb])];
    let declared: Vec<ExternalAction> = emitted
        .iter()
        .map(|c| ExternalAction::governance("l", "a", c))
        .collect();
    check_bundle_provenance("t", &gov(&emitted), &declared).expect("identical bundle");
}

/// The defect a headcount cannot see: the script declares one action and emits a different
/// call, in equal numbers.
#[test]
fn a_substituted_call_fails_even_at_the_declared_count() {
    let declared = vec![ExternalAction::governance("l", "a", &call(0x11, &[0xaa]))];
    let err = check_bundle_provenance("t", &gov(&[call(0x11, &[0xbb])]), &declared)
        .expect_err("substituted calldata must fail");
    assert!(
        err.to_string().contains("no declared external action"),
        "unexpected error: {err}"
    );
}

#[test]
fn a_declared_action_that_is_never_emitted_fails() {
    let declared = vec![ExternalAction::governance("l", "a", &call(0x11, &[0xaa]))];
    let err = check_bundle_provenance("t", &gov(&[]), &declared)
        .expect_err("an unemitted declaration must fail");
    assert!(
        err.to_string().contains("never emits"),
        "unexpected error: {err}"
    );
}

/// A prepare that emits its declared actions in another order than it declares them fails:
/// the verifier holds the merged bundle's external actions to their declared order.
#[test]
fn a_bundle_out_of_its_declared_order_fails() {
    let (first, second) = (call(0x11, &[0xaa]), call(0x22, &[0xbb]));
    let declared = vec![
        ExternalAction::governance("l", "a", &first),
        ExternalAction::governance("l", "a", &second),
    ];
    let err = check_bundle_provenance("t", &gov(&[second, first]), &declared)
        .expect_err("a reordered bundle must fail");
    assert!(err.to_string().contains("another order"), "{err}");
}

const CORE_EXECUTOR: Address = Address::repeat_byte(0xe0);
const CTM_EXECUTOR: Address = Address::repeat_byte(0xe7);
const CORE_TRANSITION: Address = Address::repeat_byte(0xee);
const INFRASTRUCTURE: Address = Address::repeat_byte(0x1f);
const TRANSITION: Address = Address::repeat_byte(0xcc);

/// The encoding of one leg, transcribed independently of the `sol!` block the merge uses:
/// the selector from the executors' compiled `methodIdentifiers`, then the object word.
fn transcribed_leg(executor: Address, selector: [u8; 4], object: Address) -> GovernanceCall {
    let mut data = selector.to_vec();
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(object.as_slice());
    GovernanceCall {
        target: executor,
        value: alloy::primitives::U256::ZERO,
        data,
    }
}

fn core_leg() -> GovernanceCall {
    transcribed_leg(CORE_EXECUTOR, [0x60, 0x93, 0xa2, 0x59], CORE_TRANSITION)
}

fn infrastructure_leg() -> GovernanceCall {
    transcribed_leg(CTM_EXECUTOR, [0x68, 0xe9, 0x89, 0x78], INFRASTRUCTURE)
}

fn transition_leg() -> GovernanceCall {
    transcribed_leg(CTM_EXECUTOR, [0x7b, 0x1b, 0x71, 0x6a], TRANSITION)
}

/// The transcribed selectors are the entrypoints' real ones.
#[test]
fn the_transcribed_selectors_are_the_executor_entrypoints() {
    for (leg, signature) in [
        (core_leg(), "applyL1Upgrade(address)"),
        (infrastructure_leg(), "applyInfrastructureUpgrade(address)"),
        (transition_leg(), "applyCTMUpgrade(address)"),
    ] {
        assert_eq!(
            &leg.data[..4],
            &alloy::primitives::keccak256(signature.as_bytes())[..4],
            "{signature}"
        );
    }
}

fn address_value(address: Address) -> toml::Value {
    toml::Value::String(format!("{address:#x}"))
}

/// A prepare body whose `[registry]` reports `entries`.
fn registry_body(entries: &[(&str, Address)]) -> toml::value::Table {
    let mut registry = toml::value::Table::new();
    for (key, address) in entries {
        registry.insert(key.to_string(), address_value(*address));
    }
    let mut body = toml::value::Table::new();
    body.insert("registry".into(), toml::Value::Table(registry));
    body
}

/// The core prepare's summary: its executor always, its transition when it deployed one.
fn core_body(transition: Option<Address>) -> toml::value::Table {
    registry_body(&[
        ("core_transition_addr", transition.unwrap_or(Address::ZERO)),
        ("core_upgrade_executor_addr", CORE_EXECUTOR),
    ])
}

/// The CTM prepare's summary, every object zero unless set.
fn ctm_body(entries: &[(&str, Address)]) -> toml::value::Table {
    let mut all: Vec<(&str, Address)> = vec![
        ("ctm_transition_addr", Address::ZERO),
        ("ctm_infrastructure_transition_addr", Address::ZERO),
        ("bootstrap_migration_addr", Address::ZERO),
        ("ctm_upgrade_executor_addr", CTM_EXECUTOR),
    ];
    for (key, address) in entries {
        match all.iter_mut().find(|(k, _)| k == key) {
            Some(entry) => entry.1 = *address,
            None => all.push((key, *address)),
        }
    }
    registry_body(&all)
}

fn derive(
    core: toml::value::Table,
    ctm: Option<toml::value::Table>,
) -> anyhow::Result<Vec<GovernanceCall>> {
    let ctms: Vec<(Address, toml::value::Table)> = ctm
        .into_iter()
        .map(|body| (Address::repeat_byte(0x77), body))
        .collect();
    derive_executor_legs(
        &core,
        &ctms
            .iter()
            .map(|(proxy, body)| (*proxy, body))
            .collect::<Vec<_>>(),
    )
}

fn targets_and_data(calls: &[GovernanceCall]) -> Vec<(Address, Vec<u8>)> {
    calls.iter().map(|c| (c.target, c.data.clone())).collect()
}

/// All three legs, in canonical order: core, CTM infrastructure, CTM transition — each sent
/// to its domain's executor with no value.
#[test]
fn all_three_legs_derive_in_canonical_order() {
    let legs = derive(
        core_body(Some(CORE_TRANSITION)),
        Some(ctm_body(&[
            ("ctm_transition_addr", TRANSITION),
            ("ctm_infrastructure_transition_addr", INFRASTRUCTURE),
        ])),
    )
    .unwrap();
    assert_eq!(
        targets_and_data(&legs),
        targets_and_data(&[core_leg(), infrastructure_leg(), transition_leg()])
    );
    assert!(legs.iter().all(|leg| leg.value.is_zero()));
}

/// Each leg alone — a core-only package needing no CTM prepare at all.
#[test]
fn each_leg_derives_alone() {
    let core_only = derive(core_body(Some(CORE_TRANSITION)), None).unwrap();
    assert_eq!(
        targets_and_data(&core_only),
        targets_and_data(&[core_leg()])
    );

    let infrastructure_only = derive(
        core_body(None),
        Some(ctm_body(&[(
            "ctm_infrastructure_transition_addr",
            INFRASTRUCTURE,
        )])),
    )
    .unwrap();
    assert_eq!(
        targets_and_data(&infrastructure_only),
        targets_and_data(&[infrastructure_leg()])
    );

    let transition_only = derive(
        core_body(None),
        Some(ctm_body(&[("ctm_transition_addr", TRANSITION)])),
    )
    .unwrap();
    assert_eq!(
        targets_and_data(&transition_only),
        targets_and_data(&[transition_leg()])
    );
}

/// A bootstrap edge derives no leg: its core transition rides the bootstrap's own sequence.
#[test]
fn a_bootstrap_derives_no_leg() {
    let legs = derive(
        core_body(Some(CORE_TRANSITION)),
        Some(ctm_body(&[(
            "bootstrap_migration_addr",
            Address::repeat_byte(0x55),
        )])),
    )
    .unwrap();
    assert!(legs.is_empty());
}

/// A bootstrap reporting a CTM-domain object would ship an object nothing applies.
#[test]
fn a_bootstrap_with_a_ctm_object_is_refused() {
    for key in ["ctm_transition_addr", "ctm_infrastructure_transition_addr"] {
        let err = derive(
            core_body(None),
            Some(ctm_body(&[
                ("bootstrap_migration_addr", Address::repeat_byte(0x55)),
                (key, TRANSITION),
            ])),
        )
        .unwrap_err();
        assert!(err.to_string().contains("derives no executor leg"), "{err}");
        assert!(err.to_string().contains(key), "{err}");
    }
}

/// A replacement derives no leg: its `ctm_transition_addr` is the replacement, which its one
/// declared `forward` installs.
#[test]
fn a_replacement_derives_no_leg() {
    let legs = derive(
        core_body(None),
        Some(ctm_body(&[
            ("ctm_transition_addr", TRANSITION),
            ("replacement_transition_addr", TRANSITION),
        ])),
    )
    .unwrap();
    assert!(legs.is_empty());
}

/// A core transition (or an infrastructure object) prepared beside a replacement is refused.
#[test]
fn a_core_transition_on_a_replacement_is_refused() {
    let err = derive(
        core_body(Some(CORE_TRANSITION)),
        Some(ctm_body(&[
            ("ctm_transition_addr", TRANSITION),
            ("replacement_transition_addr", TRANSITION),
        ])),
    )
    .unwrap_err();
    assert!(err.to_string().contains("core_transition_addr"), "{err}");
    assert!(err.to_string().contains("carries no executor leg"), "{err}");

    let err = derive(
        core_body(None),
        Some(ctm_body(&[
            ("ctm_infrastructure_transition_addr", INFRASTRUCTURE),
            ("replacement_transition_addr", TRANSITION),
        ])),
    )
    .unwrap_err();
    assert!(
        err.to_string()
            .contains("ctm_infrastructure_transition_addr"),
        "{err}"
    );
}

#[test]
fn a_bootstrap_beside_a_replacement_is_refused() {
    let err = derive(
        core_body(None),
        Some(ctm_body(&[
            ("bootstrap_migration_addr", Address::repeat_byte(0x55)),
            ("replacement_transition_addr", TRANSITION),
        ])),
    )
    .unwrap_err();
    assert!(err.to_string().contains("one package is one kind"), "{err}");
}

/// A leg whose executor is missing or zero has nowhere to be sent.
#[test]
fn a_leg_without_its_executor_is_refused() {
    let mut core = core_body(Some(CORE_TRANSITION));
    core.get_mut("registry")
        .unwrap()
        .as_table_mut()
        .unwrap()
        .remove("core_upgrade_executor_addr");
    let err = derive(core, None).unwrap_err();
    assert!(
        err.to_string().contains("core_upgrade_executor_addr"),
        "{err}"
    );

    let err = derive(
        core_body(None),
        Some(ctm_body(&[
            ("ctm_transition_addr", TRANSITION),
            ("ctm_upgrade_executor_addr", Address::ZERO),
        ])),
    )
    .unwrap_err();
    assert!(
        err.to_string().contains("ctm_upgrade_executor_addr"),
        "{err}"
    );
}

/// Neither a bootstrap nor a replacement, and no object to apply: it upgrades nothing.
#[test]
fn a_package_with_no_leg_is_refused() {
    let err = derive(core_body(None), Some(ctm_body(&[]))).unwrap_err();
    assert!(err.to_string().contains("upgrades nothing"), "{err}");
    let err = derive(core_body(None), None).unwrap_err();
    assert!(err.to_string().contains("upgrades nothing"), "{err}");
}

/// An `admin` action rides no governance bundle, so it does not account for one of its calls.
#[test]
fn an_admin_action_does_not_account_for_a_bundle_call() {
    let emitted = [call(0x11, &[0xaa])];
    let mut declared = ExternalAction::governance("l", "a", &emitted[0]);
    declared.phase = "admin".to_string();
    check_bundle_provenance("t", &gov(&emitted), &[declared])
        .expect_err("an admin declaration cannot cover a governance call");
}

fn prepare_output(body: toml::value::Table, calls: &[GovernanceCall]) -> PrepareOutputParts {
    PrepareOutputParts {
        body,
        gov: gov(calls),
        external_actions: calls
            .iter()
            .map(|c| ExternalAction::governance("declared", "governance", c))
            .collect(),
    }
}

fn merged_bundle(doc: &toml::value::Table) -> Vec<GovernanceCall> {
    let hex = doc["governance_calls"]["calls"].as_str().unwrap();
    crate::common::governance_calls::decode_calls(hex).unwrap()
}

/// The one bundle's order: the merger's extras first — a bootstrap's
/// `ctm.transferOwnership(migration)` assumes governance already accepted the CTM — then the
/// core prepare's calls, the derived legs as one contiguous run, then the CTM prepare's calls.
/// Every call but the legs is declared, the extras included, and no summary table is added.
#[test]
fn the_merged_bundle_runs_extras_core_legs_then_ctm() {
    let extra = call(0xe1, &[0x01]);
    let core = call(0xc1, &[0x02]);
    let ctm = call(0xd1, &[0x03]);
    let doc = merge_prepare_outputs(
        prepare_output(
            core_body(Some(CORE_TRANSITION)),
            std::slice::from_ref(&core),
        ),
        vec![(
            Address::repeat_byte(0x77),
            prepare_output(
                ctm_body(&[
                    ("ctm_transition_addr", TRANSITION),
                    ("ctm_infrastructure_transition_addr", INFRASTRUCTURE),
                ]),
                std::slice::from_ref(&ctm),
            ),
        )],
        &[ExtraGovernanceCall {
            label: "extra",
            authority: "protocol governance",
            call: extra.clone(),
        }],
    )
    .unwrap();

    let bundle = merged_bundle(&doc);
    assert_eq!(
        targets_and_data(&bundle),
        targets_and_data(&[
            extra,
            core,
            core_leg(),
            infrastructure_leg(),
            transition_leg(),
            ctm
        ])
    );
    assert_eq!(
        doc["governance_calls"].as_table().unwrap().len(),
        1,
        "the bundle is the table's one key"
    );
    let declared: Vec<ExternalAction> = doc["external_actions"].clone().try_into().unwrap();
    assert_eq!(declared.len(), 3);
    assert!(declared.iter().all(|a| a.phase == GOVERNANCE_PHASE));
    for (i, c) in bundle.iter().enumerate() {
        let is_declared = declared.iter().any(|a| a.is_call(c));
        assert_eq!(is_declared, !(2..5).contains(&i), "call {i}");
    }
    assert!(doc.get("operation").is_none());
}

/// The merged bundle is exactly what the verifier's loader classifies as an upgrade, with the
/// legs it recovers reconciling against the summaries the merge carried over.
#[test]
fn the_merged_package_loads_as_an_upgrade() {
    let core = core_body(Some(CORE_TRANSITION));
    let mut ctm = ctm_body(&[("ctm_transition_addr", TRANSITION)]);
    let mut state_transition = toml::value::Table::new();
    state_transition.insert(
        "chain_type_manager_proxy".into(),
        address_value(Address::repeat_byte(0x77)),
    );
    ctm.insert(
        "state_transition".into(),
        toml::Value::Table(state_transition),
    );
    let doc = merge_prepare_outputs(
        prepare_output(core, &[]),
        vec![(Address::repeat_byte(0x77), prepare_output(ctm, &[]))],
        &[],
    )
    .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ecosystem.toml");
    fs::write(&path, toml::to_string(&doc).unwrap()).unwrap();
    let RegistryPackage::Upgrade(package) = RegistryPackage::load(&path).unwrap() else {
        panic!("a merged package with legs must load as an upgrade");
    };
    assert_eq!(package.legs.len(), 2);
    assert_eq!(package.legs[0].object, CORE_TRANSITION);
    assert_eq!(package.legs[1].object, TRANSITION);
}

/// After a replay, a governance TOML that is no registry package has no post-state to check
/// and reads nothing; a registry package is held against the fork, so one whose state cannot
/// be read fails the command.
#[tokio::test]
async fn the_post_replay_check_holds_only_registry_packages() {
    const UNREACHABLE: &str = "http://127.0.0.1:1";
    let dir = tempfile::tempdir().unwrap();
    let plain = dir.path().join("plain.toml");
    fs::write(
        &plain,
        format!(
            "[governance_calls]\ncalls = \"{}\"\n",
            bundle_hex(&[call(0x51, &[0x04])])
        ),
    )
    .unwrap();
    expect_applied(UNREACHABLE, &plain, Address::ZERO)
        .await
        .expect("a TOML that is no registry package is not read back");

    let doc = merge_prepare_outputs(
        prepare_output(core_body(Some(CORE_TRANSITION)), &[]),
        Vec::new(),
        &[],
    )
    .unwrap();
    let package = dir.path().join("ecosystem.toml");
    fs::write(&package, toml::to_string(&doc).unwrap()).unwrap();
    let err = expect_applied(UNREACHABLE, &package, Address::ZERO)
        .await
        .expect_err("an unreadable post-state is not a landed one");
    assert!(
        format!("{err:#}").contains("did not leave the state its package describes"),
        "{err:#}"
    );
}

/// The CTM prepare's probes reach the simulator: the merge lifts them out of
/// `[ctms.zksync_os]`, where the simulator does not look, to the top level under ZKsync OS tags.
#[test]
fn the_ctm_prepare_probes_reach_the_simulator() {
    // The bundle is the one derived transition leg: one simulator transaction.
    let mut ctm = prepare_output(ctm_body(&[("ctm_transition_addr", TRANSITION)]), &[]);
    let mut probes = toml::value::Table::new();
    for probe in ["test_create_chain", "test_upgrade_chain"] {
        probes.insert(probe.into(), bundle_hex(&[call(0x51, &[0x04])]).into());
        probes.insert(
            format!("{probe}_caller"),
            format!("{:#x}", Address::repeat_byte(0xad)).into(),
        );
    }
    ctm.body
        .insert("test_upgrade_calls".into(), toml::Value::Table(probes));
    let doc = merge_prepare_outputs(
        prepare_output(core_body(None), &[]),
        vec![(Address::repeat_byte(0x77), ctm)],
        &[],
    )
    .unwrap();
    assert!(doc["ctms"]["zksync_os"].get("test_upgrade_calls").is_none());

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ecosystem.toml");
    fs::write(&path, toml::to_string(&doc).unwrap()).unwrap();
    assert_eq!(
        crate::commands::ecosystem::simulator::simulator_transaction_tags(&path).unwrap(),
        [
            "governance",
            "test_create_chain_zkos",
            "test_upgrade_chain_zkos"
        ]
    );
}

/// A bootstrap merge derives no leg, so the bundle is the extras followed by the prepares'
/// declared calls.
#[test]
fn a_bootstrap_merge_derives_no_executor_leg() {
    let extra = call(0xe1, &[0x01]);
    let ctm = call(0xd1, &[0x03]);
    let doc = merge_prepare_outputs(
        prepare_output(core_body(Some(CORE_TRANSITION)), &[]),
        vec![(
            Address::repeat_byte(0x77),
            prepare_output(
                ctm_body(&[("bootstrap_migration_addr", Address::repeat_byte(0x55))]),
                std::slice::from_ref(&ctm),
            ),
        )],
        &[ExtraGovernanceCall {
            label: "extra",
            authority: "protocol governance",
            call: extra.clone(),
        }],
    )
    .unwrap();
    let bundle = merged_bundle(&doc);
    assert_eq!(targets_and_data(&bundle), targets_and_data(&[extra, ctm]));
}
