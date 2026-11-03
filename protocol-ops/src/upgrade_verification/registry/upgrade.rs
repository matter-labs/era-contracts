//! Verification of a registry-driven UPGRADE — the ordinary case, and the one every upgrade
//! after the bootstrap takes: governance calls the domain executors directly, one contiguous run
//! of 1..3 legs in canonical order (`protocol-docs/ecosystem-upgrade-coordination.md`):
//!
//! 1. `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)` — a Core-domain
//!    `ProxyUpgradeTransition`;
//! 2. `CTMUpgradeExecutor.applyInfrastructureUpgrade(infrastructureTransition)` — a CTM-domain
//!    `ProxyUpgradeTransition`;
//! 3. `CTMUpgradeExecutor.applyCTMUpgrade(transition)` — a `CTMTransition`.
//!
//! # The two questions, kept apart
//!
//! **What does this upgrade do?** is answered by REVIEWING THE OBJECTS, not by reconstructing
//! them from calldata. A `ProxyUpgradeTransition` pins one domain's proxy inventory; a
//! `CTMTransition` pins the release pair and derives the facet cuts and the L2 plan from it. This
//! module reads those objects live and holds each against [`construction`](super::construction)
//! — the reviewed creation code, run on the manifest the object itself serves, must land at the
//! object's address. That covers the object's WHOLE state, so it keeps covering it when someone
//! adds a derived field. Each inventory's domain is held against the domain its leg's executor
//! applies — an expectation fixed by the leg, never read from the object — and each row against
//! the live proxy of its slot ([`super::rows`]).
//!
//! **Does the signed transaction invoke the reviewed upgrade at the intended addresses, in the
//! intended order?** is answered by [`verify_upgrade_calls`]: each leg is re-encoded from the
//! reviewed executor and object and the run must appear EXACTLY ONCE, CONTIGUOUS, in canonical
//! order; every other call must be a declared governance external action, matched one for one and
//! in declared order, that reaches none of the upgrade's authorities. With no coordinator on
//! chain, this ordered bundle check is what keeps the core rows ahead of the CTM infrastructure
//! and the infrastructure ahead of the transition commit; the one governance execution keeps them
//! atomic. The legs' INTERNAL calls are NOT re-derived — the executors derive them on chain from
//! the same pinned objects, from audited code.
//!
//! Everything else this module does is the part the objects cannot answer for themselves: that
//! the executors the legs run through are the reviewed ones (their construction,
//! [`super::lifecycle`]; they set immutables, so no codehash identifies them) and bound to the
//! independently reviewed CTM and ProxyAdmins, that governance owns them with no nomination
//! outstanding, that the live state the upgrade departs from is the state it claims, and that the
//! ecosystem is READY for it (the L2 bytecodes published).

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolValue;

use crate::common::external_actions::{ExternalAction, GOVERNANCE_PHASE};
use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{expect_canonical_construction, ReviewedBuild};
use super::genesis::{judge_release_genesis, ReviewedGenesis};
use super::lifecycle::{
    verify_executor_owners, verify_lifecycle_construction, CoreExecutorReview, CtmExecutorReview,
    LifecycleBindings, LifecycleReview,
};
use super::member_construction::{MemberReview, ReviewedEnv};
use super::members::{
    verify_engine_and_l2_plan, verify_release_members, DepartingMembers, TRANSITION_ENGINES,
};
use super::package::{LegKind, UpgradePackage};
use super::provenance::{expect_code_identity, expect_code_present, tolerate};
use super::rows::{
    participating, verify_inventory, verify_inventory_construction, Inventory, InventoryReview,
};
use super::shell::verify_shell_kept;
use super::views::{
    BytecodesSupplierView, CTMReleaseView, CTMTransitionView, CommittedUpgradeView, CtmView,
    ProxyAdminView, ProxyUpgradeRow, ProxyUpgradeTransitionView,
};
use super::{format_semver, render_derived_payloads};

/// Verify a registry-driven upgrade against the live L1 it targets.
///
/// Reads, in order: each leg's object (core, infrastructure, transition — the transition preceded
/// by the live genesis expectations); the executors' construction
/// ([`verify_lifecycle_construction`]) and owners ([`verify_executor_owners`]); the CTM's and the
/// CTM-domain ProxyAdmin's owners and the CTM's pending owner (CTM legs), the ecosystem
/// ProxyAdmin's owner (core leg); the CTM's version and release (transition leg); the
/// inventories' slots and departures; the transition's readiness and its system-proxy shell. The
/// members' construction reads the sources their recorded arguments are held against as it needs
/// them ([`super::member_construction`]).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
    package: &UpgradePackage,
    expected_governance_owner: Option<Address>,
    salts: &[B256],
    env: &ReviewedEnv,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    // The set of addresses this run establishes as reviewed, for the calldata check below.
    let mut reviewed: BTreeMap<Address, String> = BTreeMap::new();
    // The CTM is the package's, held against the CTM executor's binding below.
    let members = MemberReview::new(
        &package.member_records,
        env,
        package.reported_ctm,
        package.reported_singletons.bridgehub,
    );

    result.print_info("== Package ==");
    if package.legs.is_empty() {
        result.report_error(
            "the package carries no executor leg: it upgrades nothing, and governance would sign a \
             bundle that applies no reviewed object",
        );
        return Ok(());
    }
    result.report_ok(&format!(
        "a registry-driven upgrade ({}) with {} executor leg(s), recovered from the calldata and \
         reconciled with the prepare summaries:",
        match &package.ctm_key {
            Some(key) => format!("CTM section [{key}]"),
            None => "no CTM section".to_string(),
        },
        package.legs.len()
    ));
    for leg in &package.legs {
        result.print_info(&format!(
            "    · call {}: {}({}) on {}",
            leg.index,
            leg.kind.entrypoint(),
            leg.object,
            leg.executor
        ));
    }

    // ── 1. The objects the legs apply, and the manifests their addresses commit to ──
    result.print_info("\n== Object provenance and construction ==");
    let core_rows = match package.leg(LegKind::Core) {
        Some(leg) => {
            verify_proxy_upgrade_transition(
                provider,
                build,
                result,
                "the core transition",
                leg.object,
                Inventory::Ecosystem,
                salts,
                &mut reviewed,
            )
            .await?
        }
        None => {
            result.report_ok("no core leg: this upgrade upgrades no shared singletons");
            None
        }
    };
    let infrastructure_rows = match package.leg(LegKind::Infrastructure) {
        Some(leg) => {
            verify_proxy_upgrade_transition(
                provider,
                build,
                result,
                "the CTM infrastructure transition",
                leg.object,
                Inventory::CtmDomain,
                salts,
                &mut reviewed,
            )
            .await?
        }
        None => {
            result.report_ok(
                "no CTM infrastructure leg: this upgrade swaps no CTM-domain implementation",
            );
            None
        }
    };
    let transition_edge = match package.leg(LegKind::Transition) {
        Some(leg) => {
            let mut genesis = genesis.clone();
            genesis
                .force_deployments
                .read_live(
                    provider,
                    package.reported_ctm,
                    expected_governance_owner,
                    "--expected-governance-owner",
                )
                .await;
            verify_transition(
                provider,
                build,
                ArrivingRelease::Installed(&genesis),
                result,
                &members,
                "the CTM transition",
                leg.object,
                salts,
                &mut reviewed,
            )
            .await?
        }
        None => {
            result.report_ok("no transition leg: this upgrade moves no chain version");
            None
        }
    };

    // ── 2. Authority: the executors the legs run through, and the owner they answer to ──
    result.print_info("\n== Bound authority ==");
    let core_executor = package.leg(LegKind::Core).map(|leg| leg.executor);
    let ctm_executor = package
        .legs
        .iter()
        .find(|leg| leg.kind.is_ctm())
        .map(|leg| leg.executor);
    if ctm_executor.is_some() {
        for (field, reported, what) in [
            (
                "chain_type_manager_proxy",
                package.reported_ctm,
                "the CTM this upgrade lands on",
            ),
            (
                "transparent_proxy_admin",
                package.reported_ctm_proxy_admin,
                "the CTM-domain ProxyAdmin every infrastructure row applies through",
            ),
        ] {
            if reported.is_none() {
                result.report_error(&format!(
                    "the package does not name `{field}`, so {what} cannot be held against \
                     anything the review fixes, nor can the CTM executor's binding to it"
                ));
            }
        }
    }
    let bindings = verify_lifecycle_construction(
        provider,
        build,
        result,
        &LifecycleReview {
            owner: expected_governance_owner,
            core_executor: core_executor.map(|address| CoreExecutorReview {
                address,
                proxy_admin: package.lifecycle.core_proxy_admin,
            }),
            ctm_executor: ctm_executor.map(|address| CtmExecutorReview {
                address,
                ctm: package.reported_ctm,
                ctm_proxy_admin: package.reported_ctm_proxy_admin,
            }),
            records: package.executor_records.clone(),
        },
        &mut reviewed,
    )
    .await?;
    let executors: Vec<(&str, Address)> = core_executor
        .map(|address| ("the core executor", address))
        .into_iter()
        .chain(ctm_executor.map(|address| ("the CTM executor", address)))
        .collect();
    verify_executor_owners(
        provider,
        result,
        expected_governance_owner,
        "the reviewed governance",
        &executors,
    )
    .await;

    // The authority each domain must already HOLD. Unlike a bootstrap, an upgrade hands nothing
    // over — it executes on authority the previous edge established, so authority that has since
    // drifted is a finding now rather than a revert mid-bundle.
    if let Some(ctm_executor) = ctm_executor {
        if let (Some(ctm), Some(ctm_admin)) = (bindings.ctm, bindings.ctm_proxy_admin) {
            // An executor names its CTM only as an immutable, so the reviewer is told which CTM
            // the CTM legs land on rather than left to infer it.
            result.report_ok(&format!(
                "the CTM legs land on CTM {ctm}, under ProxyAdmin {ctm_admin}"
            ));
            expect_owned_by(
                provider,
                result,
                "the CTM",
                ctm,
                ctm_executor,
                "the CTM executor",
            )
            .await;
            expect_owned_by(
                provider,
                result,
                "the CTM-domain ProxyAdmin",
                ctm_admin,
                ctm_executor,
                "the CTM executor",
            )
            .await;
            match tolerate(
                CtmView::new(ctm, provider).pendingOwner().call().await,
                result,
                "the CTM's pending owner",
            ) {
                Some(pending) if pending.is_zero() => {
                    result.report_ok("the CTM has no pending owner")
                }
                Some(pending) => result.report_error(&format!(
                    "the CTM has a pending owner {pending}: a nomination is outstanding that \
                     could take the CTM out from under the executor this upgrade runs through"
                )),
                None => {}
            }
        }
    }
    if let (Some(core_executor), Some(core_admin)) = (core_executor, bindings.core_proxy_admin) {
        expect_owned_by(
            provider,
            result,
            "the ecosystem ProxyAdmin",
            core_admin,
            core_executor,
            "the core executor",
        )
        .await;
    }

    // ── 3. The state the upgrade departs from ──
    result.print_info("\n== Departing state ==");
    let ctm = bindings.ctm.map(|ctm| CtmView::new(ctm, provider));
    if let (Some(edge), Some(ctm)) = (&transition_edge, &ctm) {
        verify_transition_departure(result, ctm, edge).await;
    }
    if let Some(rows) = &infrastructure_rows {
        match bindings.ctm_proxy_admin {
            Some(domain_admin) => {
                let outcome = verify_inventory(
                    provider,
                    build,
                    result,
                    &InventoryReview {
                        inventory: Inventory::CtmDomain,
                        rows,
                        domain_admin,
                        anchor: bindings.ctm,
                        departure_unreadable: None,
                        reported: package.reported_singletons,
                    },
                )
                .await?;
                verify_inventory_construction(provider, build, result, &members, &outcome).await?;
            }
            None => result.report_error(
                "the CTM-domain ProxyAdmin is unknown (the CTM executor's CTM_PROXY_ADMIN could \
                 not be read), so the infrastructure rows cannot be held against live",
            ),
        }
    }
    if let Some(rows) = core_rows.as_ref().filter(|rows| participating(rows) > 0) {
        match bindings.core_proxy_admin {
            Some(domain_admin) => {
                let anchor = ecosystem_anchor(provider, result, package, &bindings).await;
                let outcome = verify_inventory(
                    provider,
                    build,
                    result,
                    &InventoryReview {
                        inventory: Inventory::Ecosystem,
                        rows,
                        domain_admin,
                        anchor,
                        departure_unreadable: None,
                        reported: Default::default(),
                    },
                )
                .await?;
                verify_inventory_construction(provider, build, result, &members, &outcome).await?;
            }
            None => result.report_error(
                "the ecosystem ProxyAdmin is unknown (the core executor's PROXY_ADMIN could not \
                 be read), so the ecosystem rows cannot be held against live",
            ),
        }
    }

    // ── 4. Readiness: what the CTM's commit requires that no object can assert ──
    result.print_info("\n== Readiness ==");
    match (package.leg(LegKind::Transition), &ctm) {
        (Some(leg), Some(ctm)) => {
            verify_bytecodes_published(
                provider,
                result,
                ctm,
                Publication {
                    object: leg.object,
                    label: "the transition",
                    required_by: "`ChainTypeManager.setNewVersionUpgradeFromTransition`",
                },
            )
            .await?
        }
        (Some(_), None) => result.report_error(
            "the CTM the transition leg lands on is unknown (the CTM executor's \
             CHAIN_TYPE_MANAGER could not be read), so the transition's L2 bytecodes cannot be \
             checked for publication",
        ),
        (None, _) => result.report_ok("no transition: no L2 bytecodes need to be published"),
    }

    // ── 5. The L2 proxy logic chains crossing the edge keep ──
    if let (Some(edge), Some(ctm)) = (&transition_edge, &ctm) {
        result.print_info("\n== L2 system-proxy shell ==");
        verify_shell_kept(
            provider,
            build.identity(),
            genesis.image.as_ref().ok(),
            result,
            ctm,
            &edge.manifest,
        )
        .await;
    }

    // ── 6. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    let authorities = upgrade_authorities(package, &bindings, &reviewed);
    verify_upgrade_calls(package, &authorities, result);

    members.report_unconsulted(result);

    // ── 7. The calls no leg describes ──
    if package.external_actions.is_empty() {
        result.report_ok(
            "the prepare declared no external actions: this upgrade is entirely described by its \
             legs",
        );
    } else {
        result.print_info(&format!(
            "  {} declared external action(s) — the calls no leg describes, for review:",
            package.external_actions.len()
        ));
        for action in &package.external_actions {
            result.print_info(&format!("    · {}", action.describe()));
        }
    }

    Ok(())
}

/// The CTM must be at the transition's departing version and on its departing release, or the
/// edge is refused on chain.
async fn verify_transition_departure<P: Provider>(
    result: &mut VerificationResult,
    ctm: &CtmView::CtmViewInstance<&P>,
    edge: &TransitionEdge,
) {
    let Some(live_version) = tolerate(
        ctm.protocolVersion().call().await,
        result,
        "the CTM's live protocol version",
    ) else {
        return;
    };
    if live_version == edge.old_version {
        result.report_ok(&format!(
            "the CTM is at the transition's departing version {}",
            format_semver(live_version)
        ));
    } else {
        result.report_error(&format!(
            "the CTM is at version {} but the transition departs from {}: the version edge is \
             refused on chain",
            format_semver(live_version),
            format_semver(edge.old_version)
        ));
    }
    result.report_ok(&format!(
        "the transition moves chains to {}",
        format_semver(edge.new_version)
    ));

    let Some(live_release) = tolerate(
        ctm.currentRelease().call().await,
        result,
        "the CTM's live currentRelease()",
    ) else {
        return;
    };
    if live_release == edge.manifest.fromRelease {
        result.report_ok(&format!(
            "the transition departs from the release the CTM is actually on ({live_release})"
        ));
    } else {
        result.report_error(&format!(
            "the transition departs from release {} but the CTM is on {live_release}: the \
             release edge is refused on chain, and the two describe different starting points",
            edge.manifest.fromRelease
        ));
    }
}

/// Where the ecosystem inventory's slots are discovered: the Bridgehub of the CTM the package
/// upgrades (bound or reported), or — for a core-only package naming no CTM — the core prepare's
/// `bridgehub_proxy_addr`. `None` (reported) when neither is available.
async fn ecosystem_anchor<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    package: &UpgradePackage,
    bindings: &LifecycleBindings,
) -> Option<Address> {
    if let Some(ctm) = bindings.ctm.or(package.reported_ctm) {
        return tolerate(
            CtmView::new(ctm, provider).BRIDGE_HUB().call().await,
            result,
            "the CTM's BRIDGE_HUB(), through which the ecosystem rows' proxies are discovered",
        );
    }
    match package.reported_singletons.bridgehub {
        Some(bridgehub) => {
            result.print_info(&format!(
                "  the package names no CTM, so the ecosystem rows' proxies are discovered \
                 through the core prepare's bridgehub_proxy_addr {bridgehub}"
            ));
            Some(bridgehub)
        }
        None => {
            result.report_error(
                "the package names neither a CTM nor the core prepare's bridgehub_proxy_addr, so \
                 the ecosystem rows' proxies cannot be discovered",
            );
            None
        }
    }
}

/// Every address the upgrade's calls may legitimately reach only through its legs, each with the
/// role a reviewer reads it under: the objects this run established, the executors, the objects
/// the legs apply, the CTM and both domains' ProxyAdmins (bound and reported).
///
/// The run of legs is the complete list of what the upgrade needs from these; a call to any of
/// them outside it is authority the review never saw, so [`verify_upgrade_calls`] refuses it
/// whether the package declares it or not.
fn upgrade_authorities(
    package: &UpgradePackage,
    bindings: &LifecycleBindings,
    reviewed: &BTreeMap<Address, String>,
) -> BTreeMap<Address, String> {
    let mut authorities = reviewed.clone();
    let mut note = |addr: Option<Address>, what: &str| {
        if let Some(addr) = addr.filter(|a| !a.is_zero()) {
            authorities.entry(addr).or_insert_with(|| what.to_string());
        }
    };
    for leg in &package.legs {
        note(
            Some(leg.executor),
            if leg.kind.is_ctm() {
                "the CTM executor"
            } else {
                "the core executor"
            },
        );
        note(Some(leg.object), "an object a leg applies");
    }
    note(package.lifecycle.core_executor, "the core executor");
    note(package.reported_ctm_executor, "the CTM executor");
    note(bindings.ctm, "the CTM the CTM executor is bound to");
    note(package.reported_ctm, "the CTM the package names");
    note(
        bindings.ctm_proxy_admin,
        "the CTM-domain ProxyAdmin the CTM executor is bound to",
    );
    note(
        package.reported_ctm_proxy_admin,
        "the CTM-domain ProxyAdmin the package names",
    );
    note(
        bindings.core_proxy_admin,
        "the ecosystem ProxyAdmin the core executor is bound to",
    );
    note(
        package.lifecycle.core_proxy_admin,
        "the ecosystem ProxyAdmin the package names",
    );
    authorities
}

/// THE question about the signed transaction.
///
/// Governance signs the legs: each is re-ENCODED here from the reviewed executor and object (the
/// prepare summaries, which the loader reconciled with the calldata) and the expected run —
/// core, then CTM infrastructure, then CTM transition, each only when present — must appear in
/// the bundle EXACTLY ONCE as ONE CONTIGUOUS run. A run out of canonical order, interrupted by
/// another call, or naming another executor or object is an ERROR: with no coordinator, the order
/// the bundle states IS the order the domains apply in.
///
/// Every other call is held to two rules. A call reaching any of `authorities` — the executors,
/// the objects, the CTM, either ProxyAdmin — is an ERROR whether declared or not: the run is the
/// complete list of what the upgrade needs from them. Every remaining call must be one of the
/// declared governance external actions, matched ONE FOR ONE and in DECLARED ORDER (the order the
/// prepares emitted them in, `ExternalActionsLib.callsForPhase`), and every declared one must
/// appear: an undeclared, duplicated, reordered or missing action is an ERROR.
pub(super) fn verify_upgrade_calls(
    package: &UpgradePackage,
    authorities: &BTreeMap<Address, String>,
    result: &mut VerificationResult,
) {
    let calls = &package.calls;
    let expected: Vec<(LegKind, GovernanceCall)> = LegKind::CANONICAL_ORDER
        .into_iter()
        .filter_map(|kind| {
            let object = package.reported_object(kind)?;
            let executor = package.reported_executor(kind)?;
            Some((
                kind,
                GovernanceCall {
                    target: executor,
                    value: U256::ZERO,
                    data: kind.encode(object),
                },
            ))
        })
        .collect();

    if expected.len() != package.legs.len() {
        result.report_error(&format!(
            "the bundle carries {} executor leg(s) but the package reports the object and executor \
             of {}: a leg the summaries do not account for cannot be re-encoded from reviewed \
             values",
            package.legs.len(),
            expected.len()
        ));
    }

    // ── the run of legs ──
    let matches = |call: &GovernanceCall, expected: &GovernanceCall| {
        call.target == expected.target && call.value == expected.value && call.data == expected.data
    };
    let runs: Vec<usize> = if expected.is_empty() {
        Vec::new()
    } else {
        calls
            .windows(expected.len())
            .enumerate()
            .filter(|(_, window)| {
                window
                    .iter()
                    .zip(&expected)
                    .all(|(call, (_, expected))| matches(call, expected))
            })
            .map(|(at, _)| at)
            .collect()
    };
    match runs.as_slice() {
        [at] => {
            result.report_ok(&format!(
                "the bundle carries the {} reviewed leg(s) as one contiguous run in canonical \
                 order (core -> CTM infrastructure -> CTM transition), at calls {at}..{} of {}",
                expected.len(),
                at + expected.len(),
                calls.len()
            ));
            for (kind, call) in &expected {
                result.print_info(&format!(
                    "    · {} on {} (authority: the executor's owner, governance)",
                    kind.entrypoint(),
                    call.target
                ));
            }
        }
        [] => report_broken_run(package, expected.len(), result),
        many => result.report_error(&format!(
            "the bundle carries the reviewed run of legs {} times (at calls {many:?}): the second \
             application is not a bundle the merge produces",
            many.len()
        )),
    }

    // ── every other call ──
    let leg_indices: Vec<usize> = package.legs.iter().map(|leg| leg.index).collect();
    let run_start = package.legs.iter().map(|leg| leg.index).min();
    let mut others: Vec<(usize, &GovernanceCall)> = Vec::new();
    for (index, call) in calls.iter().enumerate() {
        if leg_indices.contains(&index) {
            continue;
        }
        match authorities.get(&call.target) {
            Some(what) => result.report_error(&format!(
                "call {index} reaches {what} ({}) with selector 0x{} outside the run of legs: the \
                 upgrade's authorities take exactly its legs, so an extra call to one — a \
                 nomination, a `forward`, a second application — is authority the review never \
                 saw, whether or not the package declares it",
                call.target,
                alloy::hex::encode(call.data.get(..4).unwrap_or_default())
            )),
            None => others.push((index, call)),
        }
    }
    judge_external_actions(&others, &package.external_actions, run_start, result);
}

/// Names why the expected run is not in the bundle: the legs out of canonical order, the legs
/// not contiguous, or a leg whose re-encoding the bundle does not carry.
fn report_broken_run(package: &UpgradePackage, expected: usize, result: &mut VerificationResult) {
    let legs = &package.legs;
    if expected == 0 {
        result.report_error(
            "the package reports no leg object, so there is no reviewed run to hold the bundle \
             against",
        );
        return;
    }
    if legs.windows(2).any(|pair| pair[0].kind > pair[1].kind) {
        let order: Vec<&str> = legs.iter().map(|leg| leg.kind.entrypoint()).collect();
        result.report_error(&format!(
            "swapped order: the bundle runs its legs as {} — the canonical order is core -> CTM \
             infrastructure -> CTM transition, so a domain would apply before the one it depends \
             on",
            order.join(" -> ")
        ));
        return;
    }
    if let Some(pair) = legs
        .windows(2)
        .find(|pair| pair[1].index != pair[0].index + 1)
    {
        result.report_error(&format!(
            "the legs are not one contiguous run: call(s) {}..{} sit between {} (call {}) and {} \
             (call {}), so another instruction would execute between two domains' legs",
            pair[0].index + 1,
            pair[1].index,
            pair[0].kind.entrypoint(),
            pair[0].index,
            pair[1].kind.entrypoint(),
            pair[1].index
        ));
        return;
    }
    result.report_error(&format!(
        "the bundle's {} call(s) do not contain the {expected} reviewed leg(s), re-encoded from \
         the reviewed executors and objects, as one run: governance would sign a bundle the \
         reviewed upgrade does not describe",
        package.calls.len()
    ));
}

/// The calls outside the run against the declared governance external actions: one for one, in
/// declared order, every declaration present. `run_start` is where the legs begin, to report on
/// which side of them each action runs.
fn judge_external_actions(
    others: &[(usize, &GovernanceCall)],
    declared: &[ExternalAction],
    run_start: Option<usize>,
    result: &mut VerificationResult,
) {
    let declared: Vec<&ExternalAction> = declared
        .iter()
        .filter(|action| action.phase == GOVERNANCE_PHASE)
        .collect();
    let mut claimed = vec![false; declared.len()];
    let mut order: Vec<usize> = Vec::with_capacity(others.len());
    let mut accounted = true;
    for (index, call) in others {
        let selector = alloy::hex::encode(call.data.get(..4).unwrap_or_default());
        match (0..declared.len()).find(|&i| !claimed[i] && declared[i].is_call(call)) {
            Some(i) => {
                claimed[i] = true;
                order.push(i);
                let side = match run_start {
                    Some(start) if *index < start => "before",
                    Some(_) => "after",
                    None => "beside",
                };
                result.print_info(&format!(
                    "  call {index} -> declared external action `{}` on {} (selector \
                     0x{selector}), {side} the legs",
                    declared[i].label, call.target
                ));
            }
            None if declared.iter().any(|action| action.is_call(call)) => {
                accounted = false;
                result.report_error(&format!(
                    "call {index} to {} (selector 0x{selector}) repeats a declared governance \
                     external action more often than it is declared: each declaration accounts \
                     for exactly one call",
                    call.target
                ));
            }
            None => {
                accounted = false;
                result.report_error(&format!(
                    "call {index} to {} (selector 0x{selector}) is neither a leg of this upgrade \
                     nor a declared governance external action: the bundle carries an \
                     instruction no part of this review accounts for",
                    call.target
                ));
            }
        }
    }
    for (i, action) in declared.iter().enumerate() {
        if !claimed[i] {
            accounted = false;
            result.report_error(&format!(
                "the package declares a governance external action the bundle never carries — {}: \
                 the declaration a reviewer reads describes a call governance would not sign",
                action.describe()
            ));
        }
    }
    if order.windows(2).any(|pair| pair[0] > pair[1]) {
        accounted = false;
        result.report_error(
            "the declared governance external actions appear out of their declared order: the \
             prepares emit them in declaration order, so a reordered bundle is not the one they \
             produced",
        );
    }
    if accounted && !others.is_empty() {
        result.report_ok(
            "every call outside the run of legs is a declared governance external action, one \
             for one and in declared order, to a target outside the upgrade's authorities",
        );
    }
}

/// The transition as the departing-state check reads it: the manifest its address commits to, and
/// the version edge it serves — read off its two releases at construction, so no manifest field.
pub(super) struct TransitionEdge {
    pub(super) manifest: super::views::TransitionManifest,
    pub(super) old_version: U256,
    pub(super) new_version: U256,
}

/// How [`verify_transition`] treats the releases a transition names.
#[derive(Clone, Copy)]
pub(super) enum ArrivingRelease<'a> {
    /// The package deployed the arriving release: its construction and its genesis (against the
    /// reviewed one) are verified, and the departing release is identified against the commit.
    Installed(&'a ReviewedGenesis),
    /// Both releases already exist — possibly built by an earlier commit — and the caller judges
    /// them by identity with live objects (a replacement's continuation release), so they are only
    /// required to hold code.
    Existing,
}

/// The transition's provenance, construction and derived payload; `label` names it in the
/// report.
#[allow(clippy::too_many_arguments)]
pub(super) async fn verify_transition<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    arriving: ArrivingRelease<'_>,
    result: &mut VerificationResult,
    members: &MemberReview<'_>,
    label: &str,
    transition: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Option<TransitionEdge>> {
    expect_code_identity(
        provider,
        build,
        result,
        label,
        transition,
        &["CTMTransition"],
    )
    .await?;
    let view = CTMTransitionView::new(transition, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "{label} at {transition} does not answer `getManifest()` ({e}): its construction \
                 cannot be verified"
            ));
            return Ok(None);
        }
    };
    if expect_canonical_construction(
        build,
        result,
        label,
        transition,
        "CTMTransition",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(transition, label.to_string());
    }

    match arriving {
        ArrivingRelease::Installed(genesis) => {
            // The arriving release is a member the transition NAMES, so its own construction is
            // verified separately — the transition's address commits to the release's ADDRESS,
            // not to its state.
            let departing =
                DepartingMembers::of_release(provider, result, manifest.fromRelease).await;
            verify_release(
                provider,
                build,
                genesis,
                result,
                members,
                "the release the transition installs",
                manifest.newRelease,
                salts,
                &departing,
                reviewed,
            )
            .await?;
            expect_code_identity(
                provider,
                build,
                result,
                "the release the transition departs from",
                manifest.fromRelease,
                &["CTMRelease"],
            )
            .await?;
        }
        ArrivingRelease::Existing => {
            for (what, release) in [
                ("the release the transition lands on", manifest.newRelease),
                (
                    "the release the transition departs from",
                    manifest.fromRelease,
                ),
            ] {
                if expect_code_present(provider, result, what, release).await? {
                    result.print_info(&format!("  {what}: the existing release {release}"));
                }
            }
        }
    }
    verify_engine_and_l2_plan(
        provider,
        build,
        result,
        members,
        label,
        manifest.upgradeEngine,
        TRANSITION_ENGINES,
        &manifest.l2Plan,
    )
    .await?;

    render_facet_cuts(&view, result, transition).await;
    render_derived_payloads(provider, result, transition).await;
    let Some(old_version) = tolerate(
        view.oldProtocolVersion().call().await,
        result,
        "the transition's oldProtocolVersion()",
    ) else {
        return Ok(None);
    };
    let Some(new_version) = tolerate(
        view.newProtocolVersion().call().await,
        result,
        "the transition's newProtocolVersion()",
    ) else {
        return Ok(None);
    };
    Ok(Some(TransitionEdge {
        manifest,
        old_version,
        new_version,
    }))
}

/// A release's provenance and construction, re-derived from the manifest it serves, the members it
/// names, its genesis against the reviewed one, and its own `validate()`.
#[allow(clippy::too_many_arguments)]
pub(super) async fn verify_release<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
    result: &mut VerificationResult,
    members: &MemberReview<'_>,
    label: &str,
    release: Address,
    salts: &[B256],
    departing: &DepartingMembers,
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<()> {
    expect_code_identity(provider, build, result, label, release, &["CTMRelease"]).await?;
    let view = CTMReleaseView::new(release, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "{label} at {release} does not answer `getManifest()` ({e}): its construction \
                 cannot be verified"
            ));
            return Ok(());
        }
    };
    if expect_canonical_construction(
        build,
        result,
        label,
        release,
        "CTMRelease",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(release, label.to_string());
    }
    result.print_info(&format!(
        "  release manifest: protocolVersion {}, diamondInit {}, verifier {}, genesisUpgrade {}, \
         {} facet row(s), {} L2 bytecode slot(s)",
        format_semver(manifest.protocolVersion),
        manifest.diamondInit,
        manifest.verifier,
        manifest.genesisUpgrade,
        manifest.genesisFacets.len(),
        manifest.l2BytecodeInfos.len()
    ));
    for (i, row) in manifest.genesisFacets.iter().enumerate() {
        result.print_info(&format!(
            "    facet {i}: {} (freezable: {})",
            row.facet, row.isFreezable
        ));
    }
    verify_release_members(
        provider, build, result, members, label, &manifest, departing,
    )
    .await?;
    judge_release_genesis(result, label, &manifest, genesis);
    judge_release_validity(
        result,
        label,
        release,
        view.validate().call().await.map(|_| ()),
    );
    Ok(())
}

/// The release's own `validate()`, called before the vote. It is state-independent and runs on
/// chain when a transition is built over the release, in the bootstrap's `validate()`, and when
/// the CTM installs it, so a revert here is the release failing every one of them.
fn judge_release_validity(
    result: &mut VerificationResult,
    label: &str,
    release: Address,
    outcome: Result<(), alloy::contract::Error>,
) {
    use super::views::CTMReleaseView::CTMReleaseViewErrors;
    let Err(error) = outcome else {
        result.report_ok(&format!(
            "{label}: `validate()` passes — its members hold code, every facet describes \
             selectors and no selector is routed twice"
        ));
        return;
    };
    // A node may report a revert without data with no `data` field at all.
    let revert = error.as_revert_data().or_else(|| {
        error
            .to_string()
            .contains("revert")
            .then(alloy::primitives::Bytes::new)
    });
    let why = match revert {
        Some(data) if data.is_empty() => {
            "it reverts without data: a facet does not answer `selectors()`".to_string()
        }
        Some(data) => match error.as_decoded_interface_error::<CTMReleaseViewErrors>() {
            Some(CTMReleaseViewErrors::RegistryTargetHasNoCode(e)) => format!(
                "`RegistryTargetHasNoCode({})`: its diamondInit, genesisUpgrade, verifier or a \
                 facet has no code",
                e.target
            ),
            Some(CTMReleaseViewErrors::RegistryEmptySelectors(e)) => format!(
                "`RegistryEmptySelectors({})`: that facet describes no selectors, an empty cut \
                 every chain's diamond rejects",
                e.facet
            ),
            Some(CTMReleaseViewErrors::RegistryDuplicateSelector(e)) => format!(
                "`RegistryDuplicateSelector({})`: two facets route the same selector",
                e.selector
            ),
            None => format!("it reverts with 0x{}", alloy::hex::encode(&data)),
        },
        None => format!("it could not be called ({error})"),
    };
    result.report_error(&format!(
        "{label} at {release} fails its own `validate()` — {why}. The CTM runs it when it installs \
         the release, so governance's execution would revert"
    ));
}

/// A `ProxyUpgradeTransition`'s provenance and construction, and its domain held against
/// `expected` — the domain of the leg that applies it (the core leg's executor applies only Core,
/// the infrastructure leg's only CTM), fixed by the caller and never read from the object.
/// Returns the whole enum-indexed inventory it pins, for [`verify_inventory`], or `None` when it
/// cannot be read or belongs to another domain (both reported).
#[allow(clippy::too_many_arguments)]
pub(super) async fn verify_proxy_upgrade_transition<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    transition: Address,
    expected: Inventory,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Option<Vec<ProxyUpgradeRow>>> {
    expect_code_identity(
        provider,
        build,
        result,
        label,
        transition,
        &["ProxyUpgradeTransition"],
    )
    .await?;
    let view = ProxyUpgradeTransitionView::new(transition, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "{label} at {transition} does not answer `getManifest()` ({e}): its construction \
                 cannot be verified"
            ));
            return Ok(None);
        }
    };
    if expect_canonical_construction(
        build,
        result,
        label,
        transition,
        "ProxyUpgradeTransition",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(transition, label.to_string());
    }
    if manifest.domain != expected.domain_tag() {
        result.report_error(&format!(
            "{label} at {transition} is a {}-domain object, but its leg applies {}-domain rows: \
             the executor refuses it (`ProxyUpgradeDomainMismatch`), and its inventory is not \
             indexed by the enum this leg's rows are",
            Inventory::domain_name(manifest.domain),
            Inventory::domain_name(expected.domain_tag())
        ));
        return Ok(None);
    }
    if participating(&manifest.proxyUpgrades) == 0 {
        result.report_error(&format!(
            "{label} at {transition} upgrades nothing: no slot of its inventory has a nonzero \
             `implNew`, which the object's constructor refuses; omit the leg instead"
        ));
    }
    result.print_info(&format!(
        "  {label}: a {}-domain inventory of {} slot(s), {} participating",
        Inventory::domain_name(manifest.domain),
        manifest.proxyUpgrades.len(),
        participating(&manifest.proxyUpgrades)
    ));
    Ok(Some(manifest.proxyUpgrades))
}

/// An object serving `l2Plan()` whose factory dependencies must be published before the call that
/// commits it.
pub(super) struct Publication<'a> {
    pub(super) object: Address,
    /// The object, as the report names it.
    pub(super) label: &'a str,
    /// The call that refuses an unpublished dependency.
    pub(super) required_by: &'a str,
}

/// Every bytecode the object's L2 transaction depends on must ALREADY be published on the CTM's
/// supplier: `required_by` refuses it otherwise, and an unpublished dependency would fail the
/// committed edge on every chain's L2 leg rather than on L1.
///
/// This is a READINESS check and nothing more — it says the upgrade can execute, never that any
/// value is safe.
pub(super) async fn verify_bytecodes_published<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    ctm: &super::views::CtmView::CtmViewInstance<&P>,
    publication: Publication<'_>,
) -> anyhow::Result<()> {
    let Publication {
        object,
        label,
        required_by,
    } = publication;
    let Some(supplier_addr) = tolerate(
        ctm.L1_BYTECODES_SUPPLIER().call().await,
        result,
        "the CTM's L1_BYTECODES_SUPPLIER",
    ) else {
        return Ok(());
    };
    let Ok(plan) = CommittedUpgradeView::new(object, provider)
        .l2Plan()
        .call()
        .await
    else {
        result.report_error(&format!(
            "{label} at {object} does not answer `l2Plan()`, so its factory dependencies cannot \
             be checked for publication"
        ));
        return Ok(());
    };
    if plan.factoryDepHashes.is_empty() {
        result.report_ok(&format!(
            "{label}'s L2 plan depends on no factory bytecodes"
        ));
        return Ok(());
    }

    let supplier = BytecodesSupplierView::new(supplier_addr, provider);
    let mut blocks = Vec::with_capacity(plan.factoryDepHashes.len());
    for hash in &plan.factoryDepHashes {
        let hash: B256 = (*hash).into();
        let block = tolerate(
            supplier.evmPublishingBlock(hash).call().await,
            result,
            &format!("the supplier's publication block for {hash}"),
        );
        blocks.push((hash, block));
    }
    judge_bytecode_publication(result, supplier_addr, &blocks, required_by);
    Ok(())
}

/// The publication verdict over `(hash, publishing block)` pairs; an unreadable block (`None`) was
/// already reported when read. `required_by` names the call that refuses an unpublished one.
pub(super) fn judge_bytecode_publication(
    result: &mut VerificationResult,
    supplier: Address,
    publication: &[(B256, Option<U256>)],
    required_by: &str,
) {
    let mut unpublished = 0usize;
    for (hash, block) in publication {
        if block.is_some_and(|block| block.is_zero()) {
            unpublished += 1;
            result.report_error(&format!(
                "the L2 bytecode {hash} is NOT published on supplier {supplier}: {required_by} \
                 refuses it (`L2BytecodeNotPublished`)"
            ));
        }
    }
    if unpublished == 0 {
        result.report_ok(&format!(
            "all {} L2 factory dependencies are published on supplier {supplier}",
            publication.len()
        ));
    }
}

/// An `Ownable` whose owner the review fixes.
pub(super) async fn expect_owned_by<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    subject: Address,
    expected: Address,
    expected_label: &str,
) {
    // `ProxyAdminView` is used for its `owner()` getter alone; the subject is an Ownable, not
    // necessarily a ProxyAdmin.
    let Some(owner) = tolerate(
        ProxyAdminView::new(subject, provider).owner().call().await,
        result,
        &format!("{label}'s owner"),
    ) else {
        return;
    };
    if owner == expected {
        result.report_ok(&format!(
            "{label} is owned by {expected_label} ({expected})"
        ));
    } else {
        result.report_error(&format!(
            "{label} is owned by {owner}, not by {expected_label} ({expected}): this upgrade \
             executes on authority that has drifted since the last edge"
        ));
    }
}

/// Renders the facet cuts the transition DERIVED at construction, so a reviewer can read the
/// routing every chain will apply rather than trust a count.
async fn render_facet_cuts<P: Provider>(
    view: &CTMTransitionView::CTMTransitionViewInstance<&P>,
    result: &mut VerificationResult,
    transition: Address,
) {
    let Ok(cuts) = view.facetCuts().call().await else {
        result.report_error(&format!(
            "the transition at {transition} does not answer `facetCuts()`: the routing every \
             chain applies cannot be shown, so a reviewer cannot check it"
        ));
        return;
    };
    result.print_info(&format!("  derived facet cuts: {} row(s)", cuts.len()));
    for cut in cuts.iter() {
        result.print_info(&format!(
            "    {} facet {} (freezable: {}, {} selector(s))",
            match cut.action {
                0 => "Add",
                1 => "Replace",
                2 => "Remove",
                _ => "UNKNOWN action on",
            },
            cut.facet,
            cut.isFreezable,
            cut.selectors.len()
        ));
    }
}

/// Holds a value the package REPORTS against the one that actually executes.
///
/// An ERROR rather than a note: the reported field is what a human reads out of the package, and
/// the object or calldata is what executes. A disagreement means the reviewer reviewed a different
/// object from the one governance would drive.
pub(super) fn cross_check(
    result: &mut VerificationResult,
    field: &str,
    reported: Option<Address>,
    actual: Option<Address>,
    what: &str,
) {
    match (reported, actual) {
        (Some(reported), Some(actual)) if reported == actual => result.report_ok(&format!(
            "the package's reported {field} is {what} that executes"
        )),
        (Some(reported), Some(actual)) => result.report_error(&format!(
            "the package reports {field} {reported} but what executes names {actual} as {what}: \
             the summary a reviewer reads describes a different object from the executing one"
        )),
        (Some(reported), None) => result.report_error(&format!(
            "the package reports {field} {reported} but what executes carries no {what} at all"
        )),
        (None, Some(actual)) => result.report_warn(&format!(
            "the package does not report {field}, so {what} ({actual}) is known only from what \
             executes"
        )),
        (None, None) => {}
    }
}

#[cfg(test)]
mod tests;
