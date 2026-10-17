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
use super::members::{
    verify_engine_and_l2_plan, verify_release_members, DepartingVerifiers, TRANSITION_ENGINES,
};
use super::package::{LegKind, UpgradePackage};
use super::provenance::{expect_code_identity, expect_code_present, tolerate};
use super::rows::{participating, verify_inventory, Inventory, InventoryReview};
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
/// inventories' slots and departures; the transition's readiness and its system-proxy shell.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
    package: &UpgradePackage,
    expected_governance_owner: Option<Address>,
    salts: &[B256],
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    // The set of addresses this run establishes as reviewed, for the calldata check below.
    let mut reviewed: BTreeMap<Address, String> = BTreeMap::new();

    result.print_info("== Package ==");
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
                verify_inventory(
                    provider,
                    build,
                    result,
                    &InventoryReview {
                        inventory: Inventory::CtmDomain,
                        rows,
                        domain_admin,
                        anchor: bindings.ctm,
                        departure_unreadable: None,
                    },
                )
                .await?;
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
                verify_inventory(
                    provider,
                    build,
                    result,
                    &InventoryReview {
                        inventory: Inventory::Ecosystem,
                        rows,
                        domain_admin,
                        anchor,
                        departure_unreadable: None,
                    },
                )
                .await?;
            }
            None => result.report_error(
                "the ecosystem ProxyAdmin is unknown (the core executor's PROXY_ADMIN could not \
                 be read), so the ecosystem rows cannot be held against live",
            ),
        }
    }

    // ── 4. Readiness: what `applyCTMUpgrade` requires that no object can assert ──
    result.print_info("\n== Readiness ==");
    match (package.leg(LegKind::Transition), &ctm) {
        (Some(leg), Some(ctm)) => {
            verify_bytecodes_published(provider, result, ctm, leg.object).await?
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
    match package.reported_bridgehub {
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
                DepartingVerifiers::of_release(provider, result, manifest.fromRelease).await;
            verify_release(
                provider,
                build,
                genesis,
                result,
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
/// names, and its genesis against the reviewed one.
#[allow(clippy::too_many_arguments)]
pub(super) async fn verify_release<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
    result: &mut VerificationResult,
    label: &str,
    release: Address,
    salts: &[B256],
    departing: &DepartingVerifiers,
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
    verify_release_members(provider, build, result, label, &manifest, departing).await?;
    judge_release_genesis(result, label, &manifest, genesis);
    Ok(())
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
    result.print_info(&format!(
        "  {label}: a {}-domain inventory of {} slot(s), {} participating",
        Inventory::domain_name(manifest.domain),
        manifest.proxyUpgrades.len(),
        participating(&manifest.proxyUpgrades)
    ));
    Ok(Some(manifest.proxyUpgrades))
}

/// Every bytecode the transition's L2 transaction depends on must ALREADY be published on the
/// CTM's supplier: `applyCTMUpgrade` requires it, and an unpublished dependency fails the committed
/// edge on every chain's L2 leg rather than on L1.
///
/// This is a READINESS check and nothing more — it says the upgrade can execute, never that any
/// value is safe.
pub(super) async fn verify_bytecodes_published<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    ctm: &super::views::CtmView::CtmViewInstance<&P>,
    transition: Address,
) -> anyhow::Result<()> {
    let Some(supplier_addr) = tolerate(
        ctm.L1_BYTECODES_SUPPLIER().call().await,
        result,
        "the CTM's L1_BYTECODES_SUPPLIER",
    ) else {
        return Ok(());
    };
    let Ok(plan) = CommittedUpgradeView::new(transition, provider)
        .l2Plan()
        .call()
        .await
    else {
        result.report_error(&format!(
            "the transition at {transition} does not answer `l2Plan()`, so its factory \
             dependencies cannot be checked for publication"
        ));
        return Ok(());
    };
    if plan.factoryDepHashes.is_empty() {
        result.report_ok("the transition's L2 plan depends on no factory bytecodes");
        return Ok(());
    }

    let supplier = BytecodesSupplierView::new(supplier_addr, provider);
    let mut publication = Vec::with_capacity(plan.factoryDepHashes.len());
    for hash in &plan.factoryDepHashes {
        let hash: B256 = (*hash).into();
        let block = tolerate(
            supplier.evmPublishingBlock(hash).call().await,
            result,
            &format!("the supplier's publication block for {hash}"),
        );
        publication.push((hash, block));
    }
    judge_bytecode_publication(result, supplier_addr, &publication);
    Ok(())
}

/// The publication verdict over `(hash, publishing block)` pairs; an unreadable block (`None`) was
/// already reported when read.
pub(super) fn judge_bytecode_publication(
    result: &mut VerificationResult,
    supplier: Address,
    publication: &[(B256, Option<U256>)],
) {
    let mut unpublished = 0usize;
    for (hash, block) in publication {
        if block.is_some_and(|block| block.is_zero()) {
            unpublished += 1;
            result.report_error(&format!(
                "the L2 bytecode {hash} is NOT published on supplier {supplier}: \
                 `L2PlanLib.requirePublished` reverts the call that commits the transition"
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
mod tests {
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
    fn package(
        calls: Vec<GovernanceCall>,
        external_actions: Vec<ExternalAction>,
    ) -> UpgradePackage {
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
            reported_bridgehub: None,
            external_actions,
            create2_salts: Vec::new(),
            lifecycle: LifecycleInputs {
                core_executor: Some(CORE_EXECUTOR),
                core_proxy_admin: Some(ECO_ADMIN),
            },
            force_deployments_data: None,
            executor_records: Default::default(),
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

    // ───────────────────────── the whole path ─────────────────────────

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
}
