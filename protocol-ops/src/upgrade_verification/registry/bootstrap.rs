//! Verification of the one-time BOOTSTRAP edge onto the registry model.
//!
//! This is the only version-specific verifier in the tree, and it is version-specific because the
//! thing it verifies happens exactly once: a CTM that predates the registry model is handed to a
//! `CTMUpgradeExecutor`, and from then on every upgrade of that CTM is an ordinary operation
//! ([`super::operation`]). There is no second bootstrap to generalise over.
//!
//! Two things follow from an edge having no executor to invoke yet:
//!
//! * governance executes a LIST of ordinary calls rather than `stageN(operation)`, so the list has
//!   to be compared against the one `RegistryBootstrapSequence` derives — see
//!   [`verify_derived_sequence`], which says why that comparison is transitional scaffolding and
//!   must not be generalised;
//! * the objects it names (`RegistryBootstrapMigration`, the bootstrap sequence) exist only for
//!   this edge, and so do the views and checks below.
//!
//! Every object the edge names is held against its construction before anything it answers is
//! relied on — the write-once objects from the manifests they serve, the lifecycle objects
//! ([`super::lifecycle`]) and the sequence from the reviewed values they were built over. The
//! sequence in particular is the oracle the bundle is compared against, and an oracle the package
//! chose is worth nothing until the reviewed creation code is shown to have produced it.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256};
use alloy::providers::Provider;
use alloy::sol_types::SolValue;

use crate::common::external_actions::ExternalAction;
use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{constructor_args, expect_canonical_construction, ReviewedBuild};
use super::lifecycle::{
    verify_lifecycle_construction, verify_timer_construction, LifecycleBindings, LifecycleReview,
    TimerReview,
};
use super::operation::cross_check;
use super::package::{BootstrapPackage, VALIDATE_APPLIED_SELECTOR};
use super::provenance::{expect_code_identity, expect_code_present, tolerate, CodeIdentity};
use super::rows::verify_rows;
use super::views::{
    self, BridgehubView, CTMReleaseView, CTMUpgradeExecutorView, CoreTransitionView,
    CoreUpgradeExecutorView, CtmView, EcosystemUpgradeExecutorView, GovernanceUpgradeTimerView,
    ProxyUpgradeRow, RegistryBootstrapMigrationView,
};
use super::{format_semver, render_derived_payloads};

/// Verify the one-time bootstrap edge onto the registry model.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    package: &BootstrapPackage,
    expected_governance_owner: Option<Address>,
    salts: &[B256],
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    // The set of addresses this run establishes as reviewed: every object whose construction
    // re-derived. Every authority the edge touches is either one of them or a live contract the
    // manifest names, and the calldata check at the end holds each governance call against that
    // set.
    let mut reviewed: BTreeMap<Address, String> = BTreeMap::new();

    result.print_info("== Package ==");
    result.report_ok(&format!(
        "bootstrap edge on CTM section [{}]: migration {} (from the stage-1 `migrate()` call)",
        package.ctm_key, package.migration
    ));
    match package.reported_migration {
        Some(reported) if reported == package.migration => {
            result.report_ok("the reported bootstrap_migration_addr matches the executable calls")
        }
        Some(reported) => result.report_error(&format!(
            "the package reports bootstrap_migration_addr {reported} but stage 1 calls \
             `migrate()` on {}: the summary and the executable calls describe different edges",
            package.migration
        )),
        None => result.report_warn(
            "the package does not report bootstrap_migration_addr, so the migration is known \
             only from the stage-1 calldata",
        ),
    }

    // ── 1. The migration itself, and its committed manifest ──
    result.print_info("\n== Object provenance ==");
    expect_code_identity(
        provider,
        identity,
        result,
        "the bootstrap migration",
        package.migration,
        "RegistryBootstrapMigration",
    )
    .await?;

    let migration = RegistryBootstrapMigrationView::new(package.migration, provider);
    let manifest = match migration.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the object at {} does not answer `getManifest()` ({e}): it is not a \
                 RegistryBootstrapMigration, so nothing further about this package can be \
                 verified",
                package.migration
            ));
            return Ok(());
        }
    };

    // The summary a reviewer reads, against the manifest that executes. An ERROR where they
    // disagree: the reviewer would have reviewed a different edge from the one governance signs.
    for (field, reported, actual, what) in [
        (
            "ctm_release_addr",
            Some(package.release),
            manifest.currentRelease,
            "the release the edge installs",
        ),
        (
            "coordinator_addr",
            package.reported_coordinator,
            manifest.coordinator,
            "the coordinator",
        ),
        (
            "ctm_upgrade_executor_addr",
            package.reported_ctm_executor,
            manifest.ctmExecutor,
            "the CTM executor",
        ),
        (
            "chain_type_manager_proxy",
            package.reported_ctm,
            manifest.ctm,
            "the CTM",
        ),
        (
            "transparent_proxy_admin",
            package.reported_ctm_proxy_admin,
            manifest.ctmProxyAdmin,
            "the CTM-domain ProxyAdmin",
        ),
        (
            "upgrade_timer_addr",
            package.upgrade_timer,
            manifest.upgradeTimer,
            "the timer",
        ),
    ] {
        cross_check(result, field, reported, Some(actual), what);
    }

    // ── The construction check: did the reviewed creation code, run on THIS manifest, land
    //    here? A codehash cannot answer that (creation code can return canonical runtime
    //    bytecode over storage of its own choosing); an address can.
    result.print_info("\n== Object construction ==");
    if expect_canonical_construction(
        build,
        result,
        "the bootstrap migration",
        package.migration,
        "RegistryBootstrapMigration",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(package.migration, "the bootstrap migration".to_string());
    }
    verify_release_construction(
        provider,
        build,
        result,
        manifest.currentRelease,
        salts,
        &mut reviewed,
    )
    .await;
    if let Some(core_transition_addr) = package.core_transition {
        verify_core_transition_construction(
            provider,
            build,
            result,
            core_transition_addr,
            salts,
            &mut reviewed,
        )
        .await;
    }

    // The lifecycle objects, from the values the manifest and the package fix for them. The
    // owner is the manifest's: the edge hands the whole CTM domain to executors built for it,
    // and it is cross-checked against the reviewed governance address below.
    let bindings = verify_lifecycle_construction(
        provider,
        build,
        result,
        &LifecycleReview {
            owner: Some(manifest.ctmExecutorOwner),
            coordinator: manifest.coordinator,
            core_executor: package.lifecycle.core_executor,
            core_proxy_admin: package.lifecycle.core_proxy_admin,
            ctm_executor: manifest.ctmExecutor,
            ctm: Some(manifest.ctm),
            ctm_proxy_admin: Some(manifest.ctmProxyAdmin),
        },
        salts,
        &mut reviewed,
    )
    .await?;
    // GOVERNANCE starts the bootstrap's timer, not an executor: at stage 0 the executor does
    // not hold the CTM domain yet (`CTMUpgrade_v34.timerGovernance`). Only every LATER upgrade
    // binds its timer to the coordinator.
    verify_timer_construction(
        provider,
        build,
        result,
        &TimerReview {
            address: manifest.upgradeTimer,
            initial_delay: package.lifecycle.timer_initial_delay,
            governance: manifest.ctmExecutorOwner,
            reported_governance: package.lifecycle.timer_governance,
            owner: package.lifecycle.timer_owner,
        },
        salts,
        &mut reviewed,
    )
    .await?;
    let sequence =
        verify_sequence_construction(provider, build, result, package, salts, &mut reviewed)
            .await?;
    render_derived_payloads(provider, result, package.migration).await;

    result.print_info("\n== Edge state ==");
    let executed = tolerate(
        migration.executed().call().await,
        result,
        "the migration's executed() flag",
    );
    if executed == Some(true) {
        result.report_error(
            "the migration reports executed() == true: this edge has already run and cannot run \
             again (a replay is refused on-chain)",
        );
    } else {
        result.report_ok("the migration is un-executed");
    }

    expect_code_identity(
        provider,
        identity,
        result,
        "the release the edge installs",
        manifest.currentRelease,
        "CTMRelease",
    )
    .await?;

    // ── 2. Every contract the manifest names is deployed ──
    //
    // The manifest names members by ADDRESS; what those addresses RUN is what governance
    // reviewed before approving this object. What the object itself refuses — and what a
    // reviewer can check here, before the edge runs — is a member nothing is deployed to.
    result.print_info("\n== Named members ==");
    expect_code_present(
        provider,
        result,
        "manifest.upgradeEngine",
        manifest.upgradeEngine,
    )
    .await?;
    if !manifest.l2Plan.delegateComposer.is_zero() {
        expect_code_present(
            provider,
            result,
            "manifest.l2Plan.delegateComposer",
            manifest.l2Plan.delegateComposer,
        )
        .await?;
    }

    // ── 3. Authority: the bindings that are storage, and the owner the domain lands on ──
    //
    // Construction settled what each object was BUILT with; what moves afterwards — owners,
    // nominations, coordinators — is read live and held against the same reviewed values.
    result.print_info("\n== Bound authority ==");
    let executor = CTMUpgradeExecutorView::new(manifest.ctmExecutor, provider);
    let Some(bound_coordinator) = tolerate(
        executor.coordinator().call().await,
        result,
        "the executor's coordinator",
    ) else {
        return Ok(());
    };
    if bound_coordinator == manifest.coordinator {
        result.report_ok(&format!(
            "the executor answers to the coordinator the manifest names ({bound_coordinator})"
        ));
    } else {
        result.report_error(&format!(
            "the executor answers to coordinator {bound_coordinator} but the manifest names {}: \
             `migrate()` would refuse, and every later upgrade would be driven from the wrong place",
            manifest.coordinator
        ));
    }
    let Some(reserved) = tolerate(
        executor.activeOperation().call().await,
        result,
        "the executor's activeOperation()",
    ) else {
        return Ok(());
    };
    if reserved.is_zero() {
        result.report_ok("the executor holds no reservation");
    } else {
        result.report_error(&format!(
            "the executor is already reserved for operation {reserved}: the bootstrap edge hands \
             a domain over that is mid-lifecycle"
        ));
    }

    // The coordinator and the core executor it drives: the same governance owner as the CTM
    // executor, no nomination outstanding on either, and (pre-execution) an unbound core
    // executor — stage 2 binds it.
    let coordinator = EcosystemUpgradeExecutorView::new(manifest.coordinator, provider);
    let coordinator_owner = tolerate(
        coordinator.owner().call().await,
        result,
        "the coordinator's owner",
    );
    let coordinator_pending_owner = tolerate(
        coordinator.pendingOwner().call().await,
        result,
        "the coordinator's pending owner",
    );
    expect_owner_and_no_nomination(
        result,
        "the coordinator",
        coordinator_owner,
        coordinator_pending_owner,
        manifest.ctmExecutorOwner,
    );
    if let Some(core_executor_addr) = bindings.core_executor {
        let core_executor = CoreUpgradeExecutorView::new(core_executor_addr, provider);
        let core_executor_owner = tolerate(
            core_executor.owner().call().await,
            result,
            "the core executor's owner",
        );
        let core_executor_pending_owner = tolerate(
            core_executor.pendingOwner().call().await,
            result,
            "the core executor's pending owner",
        );
        expect_owner_and_no_nomination(
            result,
            "the core executor",
            core_executor_owner,
            core_executor_pending_owner,
            manifest.ctmExecutorOwner,
        );
        if let Some(bound) = tolerate(
            core_executor.coordinator().call().await,
            result,
            "the core executor's coordinator",
        ) {
            if bound == manifest.coordinator {
                result.report_ok("the core executor already answers to the coordinator");
            } else if bound.is_zero() {
                result.report_ok(
                    "the core executor answers to no coordinator yet: stage 2 binds it \
                     (`setCoordinator`, in the derived sequence)",
                );
            } else {
                result.report_error(&format!(
                    "the core executor answers to coordinator {bound}, not the manifest's {}",
                    manifest.coordinator
                ));
            }
        }
    }

    // The owner binding: the manifest states the owner the executor must already have, and the
    // migration refuses to run otherwise. Verifying it here catches a wrong owner BEFORE
    // governance signs, which is the whole point — after `migrate()` the CTM domain is that
    // owner's permanently.
    let executor_owner = tolerate(
        executor.owner().call().await,
        result,
        "the executor's owner",
    );
    let executor_pending_owner = tolerate(
        executor.pendingOwner().call().await,
        result,
        "the executor's pending owner",
    );
    expect_owner_and_no_nomination(
        result,
        "the executor",
        executor_owner,
        executor_pending_owner,
        manifest.ctmExecutorOwner,
    );

    match expected_governance_owner {
        Some(expected) if expected == manifest.ctmExecutorOwner => {
            result.report_ok(&format!(
                "the manifest's expected owner is the reviewed governance address {expected}"
            ));
        }
        Some(expected) => {
            result.report_error(&format!(
                "the manifest binds the executor to owner {} but the reviewed governance address \
                 is {expected}",
                manifest.ctmExecutorOwner
            ));
        }
        None => result.report_warn(
            "no --expected-governance-owner supplied: the owner the CTM domain lands on is \
             unverified against the review",
        ),
    }

    // ── 4. The departing state the manifest asserts ──
    result.print_info("\n== Departing state ==");
    let ctm = CtmView::new(manifest.ctm, provider);
    let Some(live_version) = tolerate(
        ctm.protocolVersion().call().await,
        result,
        "the CTM's live protocol version",
    ) else {
        return Ok(());
    };
    if live_version == manifest.expectedProtocolVersion {
        result.report_ok(&format!(
            "the CTM is at the manifest's expected departing version {}",
            format_semver(live_version)
        ));
    } else {
        result.report_error(&format!(
            "the CTM is at version {} but the manifest expects to depart from {}",
            format_semver(live_version),
            format_semver(manifest.expectedProtocolVersion)
        ));
    }

    if manifest.newProtocolVersion > live_version {
        result.report_ok(&format!(
            "the target version {} is ahead of live",
            format_semver(manifest.newProtocolVersion)
        ));
    } else {
        result.report_error(&format!(
            "the target version {} does not move forward from live {}",
            format_semver(manifest.newProtocolVersion),
            format_semver(live_version)
        ));
    }

    // Stage 1 nominates the migration as CTM owner; before the bundle nobody may be nominated,
    // or the edge's own handover would be racing an outstanding one.
    let Some(ctm_pending_owner) = tolerate(
        ctm.pendingOwner().call().await,
        result,
        "the CTM's pending owner",
    ) else {
        return Ok(());
    };
    if ctm_pending_owner.is_zero() {
        result.report_ok("the CTM has no pending owner");
    } else {
        result.report_error(&format!(
            "the CTM has a pending owner {ctm_pending_owner}: a nomination is outstanding that \
             the edge's own handover would race"
        ));
    }

    // Each CTM-domain row must depart from the implementation that is LIVE, not from whatever
    // the prepare saw: a row at an unexpected implementation reverts stage 1 wholesale.
    let ctm_rows: Vec<ProxyUpgradeRow> = manifest
        .proxyUpgrades
        .iter()
        .filter(|row| !row.implNew.is_zero())
        .cloned()
        .collect();
    verify_rows(
        provider,
        result,
        "CTM-domain row",
        &ctm_rows,
        manifest.ctmProxyAdmin,
    )
    .await?;

    // ── 5. The ecosystem leg ──
    result.print_info("\n== Ecosystem leg ==");
    if let Some(core_transition_addr) = package.core_transition {
        expect_code_identity(
            provider,
            identity,
            result,
            "the core transition",
            core_transition_addr,
            "CoreTransition",
        )
        .await?;

        let Some(eco_admin_addr) = bindings.core_proxy_admin else {
            result.report_error(
                "the ecosystem ProxyAdmin is unknown (the core executor's PROXY_ADMIN could not \
                 be read), so the ecosystem rows cannot be held against live",
            );
            return Ok(());
        };
        let registry = CoreTransitionView::new(core_transition_addr, provider);
        let Some(rows) = tolerate(
            registry.ecosystemRows().call().await,
            result,
            "the core transition's ecosystemRows()",
        ) else {
            return Ok(());
        };
        let rows: Vec<ProxyUpgradeRow> = rows
            .into_iter()
            .filter(|row| !row.implNew.is_zero())
            .collect();
        verify_rows(provider, result, "ecosystem row", &rows, eco_admin_addr).await?;
    } else {
        result.report_ok("no core transition: this edge upgrades no shared singletons");
    }

    // ── 6. The timer that gates the edge ──
    result.print_info("\n== Stage sequencing ==");
    let timer = GovernanceUpgradeTimerView::new(manifest.upgradeTimer, provider);
    let Some(timer_governance) = tolerate(
        timer.TIMER_GOVERNANCE().call().await,
        result,
        "the timer's TIMER_GOVERNANCE()",
    ) else {
        return Ok(());
    };
    if timer_governance == manifest.ctmExecutorOwner {
        result.report_ok(
            "the timer is governed by the same address that owns the executor, so governance \
             can start it at stage 0",
        );
    } else if timer_governance == manifest.ctmExecutor {
        result.report_error(
            "the timer is governed by the bound executor: correct for a recurring upgrade, but \
             at bootstrap stage 0 the executor does not hold the domain yet, so nobody can \
             start this timer",
        );
    } else {
        result.report_error(&format!(
            "the timer is governed by {timer_governance}, which neither owns the executor ({}) \
             nor is the executor itself: stage 0 could not start it",
            manifest.ctmExecutorOwner
        ));
    }

    // ── 7. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    // The pause/unpause calls land on the CTM's own ChainAssetHandler, which no manifest names;
    // it is derived from the CTM's Bridgehub so a call to it counts as that contract rather than
    // as an unexplained address. An unreadable hop is not silently tolerated: it just leaves the
    // handler out of the edge's authorities, and the pause call then reports as undeclared —
    // which is the honest outcome.
    let chain_asset_handler = match ctm.BRIDGE_HUB().call().await {
        Ok(bridgehub) => BridgehubView::new(bridgehub, provider)
            .chainAssetHandler()
            .call()
            .await
            .ok(),
        Err(_) => None,
    };
    let authorities = edge_authorities(
        &manifest,
        &bindings,
        chain_asset_handler,
        sequence,
        package.core_transition,
        &reviewed,
    );
    verify_derived_sequence(provider, result, package, sequence, &authorities).await;

    // A bootstrap edge legitimately declares external actions — the derived sequence itself
    // rides as declared actions, and so do the merge's appends. They are the reviewable list,
    // so they are PRINTED rather than flagged; what the stage check above flags is anything
    // that is neither derived nor declared, or that reaches an authority outside the sequence.
    if package.external_actions.is_empty() {
        result.report_warn(
            "the prepare declared NO external actions, which a bootstrap edge cannot be: its \
             handovers and pause window are not describable by any object",
        );
    } else {
        result.print_info(&format!(
            "  {} declared external action(s) — the calls no object describes, for review:",
            package.external_actions.len()
        ));
        for action in &package.external_actions {
            result.print_info(&format!("    · {}", action.describe()));
        }
    }

    Ok(())
}

/// The release's construction, re-derived from the manifest the release itself serves.
async fn verify_release_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    release: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) {
    let view = CTMReleaseView::new(release, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the release at {release} does not answer `getManifest()` ({e}): its construction \
                 cannot be verified"
            ));
            return;
        }
    };
    if expect_canonical_construction(
        build,
        result,
        "the release the edge installs",
        release,
        "CTMRelease",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(release, "the release the edge installs".to_string());
    }
    result.print_info(&format!(
        "  release manifest: diamondInit {}, verifier {}, genesisUpgrade {}, {} facet row(s), \
         {} L2 bytecode slot(s)",
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
}

/// The core transition's construction, re-derived from the manifest it serves.
async fn verify_core_transition_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    core_transition: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) {
    let view = CoreTransitionView::new(core_transition, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the core transition at {core_transition} does not answer `getManifest()` ({e}): its \
                 construction cannot be verified"
            ));
            return;
        }
    };
    if expect_canonical_construction(
        build,
        result,
        "the core transition",
        core_transition,
        "CoreTransition",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(core_transition, "the core transition".to_string());
    }
}

/// The bootstrap sequence's construction, from the two objects the verifier already holds — the
/// migration recovered from stage 1's `migrate()` and the package's core transition — so a
/// counterfeit terminating stage 2 fails BEFORE any list it derives is consulted.
///
/// The sequence is recovered from the terminal `validateApplied()` call rather than read from a
/// field, for the same reason the migration is recovered from `migrate()`: the verifier checks
/// the calldata governance will execute.
///
/// Returns the sequence's address once its construction re-derived, and nothing otherwise.
async fn verify_sequence_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    package: &BootstrapPackage,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Option<Address>> {
    let Some(last) = package.stage2.last() else {
        result.report_error(
            "stage 2 is empty: a derived bootstrap sequence always ends with the completion gate",
        );
        return Ok(None);
    };
    if last.data != VALIDATE_APPLIED_SELECTOR || !last.value.is_zero() {
        result.report_error(
            "stage 2 does not end with the edge's completion gate (`validateApplied()`): \
             governance would complete without the edge proving it reached the intended state, \
             and the bundle is not the one the derived sequence describes",
        );
        return Ok(None);
    }
    let label = "the bootstrap sequence terminating stage 2";
    let Some(core_transition) = package.core_transition else {
        result.report_error(&format!(
            "{label} at {}: the package names no core transition, but the sequence is constructed \
             over the edge's core transition, so its construction cannot be re-derived and the \
             stage lists it derives cannot be trusted",
            last.target
        ));
        return Ok(None);
    };
    if !expect_code_present(provider, result, label, last.target).await? {
        return Ok(None);
    }
    if expect_canonical_construction(
        build,
        result,
        label,
        last.target,
        "RegistryBootstrapSequence",
        &constructor_args::registry_bootstrap_sequence(package.migration, core_transition),
        salts,
    ) {
        reviewed.insert(last.target, label.to_string());
        Ok(Some(last.target))
    } else {
        Ok(None)
    }
}

/// An `Ownable2Step` authority the edge hands over or drives: its owner must be the reviewed
/// one, and no nomination may be outstanding — a nominee accepts after the edge and inherits
/// whatever the edge handed the authority.
fn expect_owner_and_no_nomination(
    result: &mut VerificationResult,
    label: &str,
    owner: Option<Address>,
    pending_owner: Option<Address>,
    expected_owner: Address,
) {
    match owner {
        Some(owner) if owner == expected_owner => result.report_ok(&format!(
            "{label} is owned by the governance the manifest expects ({owner})"
        )),
        Some(owner) => result.report_error(&format!(
            "{label} is owned by {owner}, not by the governance the manifest expects \
             ({expected_owner}): one lifecycle would answer to two owners, and for the CTM \
             executor `migrate()` would refuse — an unnoticed mismatch is a permanent handover to \
             the wrong owner"
        )),
        None => {}
    }
    match pending_owner {
        Some(pending) if pending.is_zero() => {
            result.report_ok(&format!("{label} has no pending owner"))
        }
        Some(pending) => result.report_error(&format!(
            "{label} has a pending owner {pending}: a nomination is outstanding that could take \
             it after the edge runs"
        )),
        None => {}
    }
}

/// Every address the edge's calls may legitimately reach, each with the role a reviewer reads
/// it under: the objects this run established, the live contracts the manifest names, and the
/// two derived from them (the ecosystem `ProxyAdmin`, the chain asset handler).
///
/// The derived sequence is the complete list of what the edge needs from these; a call to any
/// of them outside that list is authority the review never saw, so
/// [`verify_stage`] refuses it whether the package declares it or not.
fn edge_authorities(
    manifest: &views::BootstrapManifest,
    bindings: &LifecycleBindings,
    chain_asset_handler: Option<Address>,
    sequence: Option<Address>,
    core_transition: Option<Address>,
    reviewed: &BTreeMap<Address, String>,
) -> BTreeMap<Address, String> {
    let mut authorities = reviewed.clone();
    let mut note = |addr: Option<Address>, what: &str| {
        if let Some(addr) = addr.filter(|a| !a.is_zero()) {
            authorities.entry(addr).or_insert_with(|| what.to_string());
        }
    };
    note(Some(manifest.ctm), "the CTM the manifest names");
    note(
        Some(manifest.ctmProxyAdmin),
        "the CTM-domain ProxyAdmin the manifest names",
    );
    note(
        Some(manifest.ctmExecutor),
        "the CTM executor the manifest names",
    );
    note(
        Some(manifest.coordinator),
        "the coordinator the manifest names",
    );
    note(Some(manifest.upgradeTimer), "the timer the manifest names");
    note(
        Some(manifest.currentRelease),
        "the release the manifest names",
    );
    note(
        bindings.core_executor,
        "the core executor the coordinator names",
    );
    note(
        bindings.core_proxy_admin,
        "the ecosystem ProxyAdmin the core executor names",
    );
    note(core_transition, "the core transition");
    note(
        chain_asset_handler,
        "the ChainAssetHandler the CTM's Bridgehub names",
    );
    note(sequence, "the bootstrap sequence terminating stage 2");
    authorities
}

/// Compares each stage of the bundle against the list `RegistryBootstrapSequence` derives.
///
/// # This comparison is TRANSITIONAL SCAFFOLDING, and must not be generalised
///
/// It exists for one reason: a bootstrap edge has no executor to invoke, so GOVERNANCE EXECUTES
/// THE LIST rather than invoking the sequence to execute it. Reviewing the sequence contract
/// therefore does not establish that the calls governance will sign are the calls it derives —
/// only comparing them does.
///
/// Every LATER upgrade is a recurring operation, where governance signs
/// `coordinator.stageN(operation)` and the executors derive everything else on chain. That path
/// needs no list comparison and must not grow one: see
/// [`operation::verify_stage_calls`](super::operation). Do not build new machinery on top of this
/// function — when the bootstrap edge is behind us, it goes.
///
/// `sequence` is the address whose construction [`verify_sequence_construction`] re-derived from
/// the reviewed migration and core transition; with none, no list is consulted — an oracle the
/// package chose says nothing about the bundle until it is shown to be the reviewed object.
async fn verify_derived_sequence<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    package: &BootstrapPackage,
    sequence: Option<Address>,
    authorities: &BTreeMap<Address, String>,
) {
    let Some(sequence_addr) = sequence else {
        result.report_error(
            "the bootstrap sequence terminating stage 2 is not established as the reviewed \
             object built over this edge, so the calls it derives are not consulted and the \
             submitted stage calls cannot be held against anything: the bundle is unreviewed",
        );
        return;
    };
    let sequence = views::RegistryBootstrapSequenceView::new(sequence_addr, provider);
    for (stage, submitted) in [
        (0usize, &package.stage0),
        (1, &package.stage1),
        (2, &package.stage2),
    ] {
        let derived = match stage {
            0 => sequence.stage0Actions().call().await,
            1 => sequence.stage1Actions().call().await,
            _ => sequence.stage2Actions().call().await,
        };
        let derived = match derived {
            Ok(actions) => actions,
            Err(e) => {
                result.report_error(&format!(
                    "the sequence at {sequence_addr} does not answer `stage{stage}Actions()` \
                     ({e}): the submitted stage-{stage} calls cannot be held against the list it \
                     derives"
                ));
                continue;
            }
        };
        verify_stage(
            stage,
            submitted,
            &derived,
            &package.external_actions,
            authorities,
            result,
        );
    }
}

/// One stage of the bundle against the list the (construction-verified) sequence derives for it.
///
/// The derived calls must appear as one contiguous run, in order and one-for-one: the edge's
/// own steps depend on each other (the pause before the version commit, the handovers before
/// `migrate()`). Around that run the merge may append — the governance-set wiring, a Gateway
/// bring-up — and every such call is held to the rule the recurring path enforces: it must be a
/// declared external action of this phase, or it is an ERROR. One rule is stricter here. The
/// derived run is the COMPLETE list of what the edge needs from its authorities (the CTM, both
/// ProxyAdmins, the executors, the timer, the objects), so a call to any of them outside the run
/// is an ERROR whether declared or not: a `transferOwnership` nomination, a `setCoordinator`, a
/// `forward` appended after the legitimate calls is exactly how a bundle would carry authority
/// governance never reviewed, and `validateApplied()` on chain now refuses a pending nomination
/// for the same reason.
fn verify_stage(
    stage: usize,
    submitted: &[GovernanceCall],
    derived: &[views::BootstrapAction],
    declared: &[ExternalAction],
    authorities: &BTreeMap<Address, String>,
    result: &mut VerificationResult,
) {
    let run = if derived.is_empty() {
        result.report_error(&format!(
            "the sequence derives no calls for stage {stage}, which no bootstrap edge does: the \
             sequence is not describing this edge"
        ));
        None
    } else {
        submitted.windows(derived.len()).position(|window| {
            derived.iter().zip(window).all(|(action, call)| {
                action.call.target == call.target
                    && action.call.value == call.value
                    && action.call.data[..] == call.data[..]
            })
        })
    };
    match run {
        Some(at) => {
            result.report_ok(&format!(
                "stage {stage} carries the {} call(s) the sequence derives, in order (at offset \
                 {at} of {} submitted)",
                derived.len(),
                submitted.len()
            ));
            for action in derived {
                result.print_info(&format!(
                    "    · {} — {} (authority: {})",
                    action.label, action.call.target, action.authority
                ));
            }
        }
        None if !derived.is_empty() => result.report_error(&format!(
            "stage {stage}'s {} submitted call(s) do not contain the {} call(s) the sequence \
             derives, in order: governance would sign a bundle the reviewed edge does not describe",
            submitted.len(),
            derived.len()
        )),
        None => {}
    }

    let in_run = |index: usize| run.is_some_and(|at| (at..at + derived.len()).contains(&index));
    let mut extras = 0usize;
    let phase = stage.to_string();
    for (index, call) in submitted.iter().enumerate() {
        if in_run(index) {
            continue;
        }
        let selector = alloy::hex::encode(call.data.get(..4).unwrap_or_default());
        if let Some(what) = authorities.get(&call.target) {
            extras += 1;
            result.report_error(&format!(
                "stage {stage} calls {what} ({}) with selector 0x{selector} outside the derived \
                 sequence: the edge's authorities take exactly the derived calls, so an extra \
                 one — a `transferOwnership` nomination, a `setCoordinator`, a `forward` — is \
                 authority the review never saw, whether or not the package declares it",
                call.target
            ));
            continue;
        }
        match declared
            .iter()
            .find(|action| action.phase == phase && action.is_call(call))
        {
            Some(action) => result.print_info(&format!(
                "  stage {stage} -> declared external action `{}` on {} (selector 0x{selector})",
                action.label, call.target
            )),
            None => {
                extras += 1;
                result.report_error(&format!(
                    "stage {stage} calls {} (selector 0x{selector}), which is neither derived by \
                     the sequence nor a declared external action: the bundle carries an \
                     instruction no part of this review accounts for",
                    call.target
                ));
            }
        }
    }
    if extras == 0 && run.is_some() {
        result.report_ok(&format!(
            "stage {stage}: every submitted call is derived by the sequence or a declared \
             external action to a target outside the edge's authorities"
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
            proxyUpgrades: Vec::new(),
            currentRelease: Address::repeat_byte(0x33),
            newProtocolVersion: U256::from(2),
            oldProtocolVersionDeadline: U256::from(3),
            upgradeEngine: Address::repeat_byte(0x44),
            l2Plan: views::AuthoredL2Plan {
                delegateBytecodeInfo: Default::default(),
                extraBytecodeInfos: Vec::new(),
                delegateComposer: Address::ZERO,
            },
            upgradeTimestamp: U256::from(0),
            ctmExecutor: Address::repeat_byte(0x55),
            ctmExecutorOwner: Address::repeat_byte(0x66),
            coordinator: Address::repeat_byte(0x77),
            upgradeTimer: Address::repeat_byte(0x88),
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

    // ───────────────────────── the stage rule ─────────────────────────
    //
    // A stage-1 bundle shaped like the one `RegistryBootstrapSequence.stage1Actions` derives,
    // over synthetic addresses, so the rule can be driven without a chain: the derived run, the
    // authorities it touches, and what may or may not sit beside it.

    const CTM: Address = Address::repeat_byte(0x01);
    const CTM_ADMIN: Address = Address::repeat_byte(0x02);
    const ECO_ADMIN: Address = Address::repeat_byte(0x03);
    const CORE_EXECUTOR: Address = Address::repeat_byte(0x04);
    const MIGRATION: Address = Address::repeat_byte(0x05);
    const CAH: Address = Address::repeat_byte(0x06);
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

    fn derived_stage1() -> Vec<views::BootstrapAction> {
        vec![
            action(
                "re-assert the migration pause",
                CAH,
                vec![0xaa, 0xbb, 0xcc, 0xdd],
            ),
            action(
                "hand the ecosystem ProxyAdmin to the core executor",
                ECO_ADMIN,
                transfer_ownership(CORE_EXECUTOR),
            ),
            action(
                "apply the pinned ecosystem inventory",
                CORE_EXECUTOR,
                vec![0x11, 0x22, 0x33, 0x44],
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
                ExternalAction::for_stage(
                    1,
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
            (CAH, "the ChainAssetHandler"),
        ]
        .into_iter()
        .map(|(a, s)| (a, s.to_string()))
        .collect()
    }

    fn run(submitted: &[GovernanceCall], declared: &[ExternalAction]) -> VerificationResult {
        let mut result = VerificationResult::default();
        verify_stage(
            1,
            submitted,
            &derived_stage1(),
            declared,
            &authorities(),
            &mut result,
        );
        result
    }

    #[test]
    fn the_derived_run_alone_passes() {
        let derived = derived_stage1();
        let result = run(&submitted_from(&derived), &declared_from(&derived));
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
    }

    /// THE finding: `coreExecutor.transferOwnership(attacker)` appended after the legitimate
    /// run. The address is known (it takes a derived call two positions earlier), the selector
    /// is one the run itself uses, and on chain `validateApplied()` never looked at
    /// `pendingOwner()` — the nominee accepts after the bundle and owns the ecosystem domain.
    #[test]
    fn a_nomination_appended_after_the_run_fails() {
        let derived = derived_stage1();
        let mut submitted = submitted_from(&derived);
        submitted.push(call(CORE_EXECUTOR, transfer_ownership(ATTACKER)));
        let result = run(&submitted, &declared_from(&derived));
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }

    /// Declaring the appended nomination does not launder it: an authority takes exactly the
    /// derived calls, and the package author controls the declarations.
    #[test]
    fn a_declared_nomination_on_an_authority_still_fails() {
        let derived = derived_stage1();
        let extra = call(CORE_EXECUTOR, transfer_ownership(ATTACKER));
        let mut submitted = submitted_from(&derived);
        submitted.push(extra.clone());
        let mut declared = declared_from(&derived);
        declared.push(ExternalAction::for_stage(
            1,
            "re-assert the migration pause",
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
        let derived = derived_stage1();
        for (target, data) in [
            (CTM, transfer_ownership(ATTACKER)),
            (CTM_ADMIN, vec![0xde, 0xad, 0xbe, 0xef]),
            (MIGRATION, vec![0x01, 0x02, 0x03, 0x04]),
            (CAH, vec![0xaa, 0xbb, 0xcc, 0xdd]),
        ] {
            let mut submitted = submitted_from(&derived);
            submitted.insert(0, call(target, data));
            let result = run(&submitted, &declared_from(&derived));
            assert_eq!(result.errors, 1, "an extra call to {target} must fail");
        }
    }

    /// What the merge legitimately appends — the governance-set wiring on the PUH — is a
    /// declared action to a target outside the edge's authorities, and rides along.
    #[test]
    fn a_declared_append_outside_the_authorities_rides_along() {
        let derived = derived_stage1();
        let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
        let mut submitted = vec![wiring.clone()];
        submitted.extend(submitted_from(&derived));
        let mut declared = declared_from(&derived);
        declared.push(ExternalAction::for_stage(
            1,
            "wire the new governance set",
            "governance",
            &wiring,
        ));
        let result = run(&submitted, &declared);
        assert_eq!(result.errors, 0);
    }

    /// The same append UNDECLARED is the recurring path's rule, applied here too.
    #[test]
    fn an_undeclared_append_outside_the_authorities_fails() {
        let derived = derived_stage1();
        let mut submitted = submitted_from(&derived);
        submitted.push(call(PUH, vec![0x99, 0x88, 0x77, 0x66]));
        let result = run(&submitted, &declared_from(&derived));
        assert_eq!(result.errors, 1);
    }

    /// A declaration counts for its own phase only.
    #[test]
    fn a_declaration_from_another_phase_does_not_count() {
        let derived = derived_stage1();
        let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
        let mut submitted = submitted_from(&derived);
        submitted.push(wiring.clone());
        let mut declared = declared_from(&derived);
        declared.push(ExternalAction::for_stage(
            0,
            "wiring",
            "governance",
            &wiring,
        ));
        let result = run(&submitted, &declared);
        assert_eq!(result.errors, 1);
    }

    /// The run must be contiguous and in order: the handovers before `migrate()`.
    #[test]
    fn a_reordered_run_fails() {
        let derived = derived_stage1();
        let mut submitted = submitted_from(&derived);
        submitted.swap(4, 5);
        let result = run(&submitted, &declared_from(&derived));
        assert!(result.errors >= 1);
        assert!(result.ensure_success().is_err());
    }

    /// A derived call missing from the bundle is not a run at all.
    #[test]
    fn a_dropped_derived_call_fails() {
        let derived = derived_stage1();
        let mut submitted = submitted_from(&derived);
        submitted.remove(2);
        let result = run(&submitted, &declared_from(&derived));
        assert!(result.errors >= 1);
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

    fn package_ending_on(sequence: Address) -> BootstrapPackage {
        BootstrapPackage {
            core_transition: Some(CORE_TRANSITION),
            release: Address::repeat_byte(0x09),
            upgrade_timer: None,
            migration: MIGRATION,
            reported_migration: None,
            reported_coordinator: None,
            reported_ctm_executor: None,
            reported_ctm: None,
            reported_ctm_proxy_admin: None,
            ctm_key: "zksync_os".to_string(),
            stage0: Vec::new(),
            stage1: Vec::new(),
            stage2: vec![call(sequence, VALIDATE_APPLIED_SELECTOR.to_vec())],
            external_actions: Vec::new(),
            create2_salts: Vec::new(),
            lifecycle: Default::default(),
        }
    }

    /// THE finding: the oracle the bundle is compared against was whatever address the package
    /// chose. A counterfeit sequence answering the reviewed `MIGRATION()` and `CORE_TRANSITION()`
    /// with attacker-chosen stage lists passed, and its address was accounted for as a target.
    /// Now its construction — from the migration and core transition the verifier already holds —
    /// fails first, and nothing it derives is ever read: the queued stage-list answers stay
    /// unconsumed.
    #[tokio::test]
    async fn a_counterfeit_sequence_is_never_consulted() {
        let counterfeit = Address::repeat_byte(0xCF);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(&[0x60, 0x00])); // it has code
        for _ in 0..3 {
            // the attacker-chosen lists it would answer with
            asserter.push_success(&Bytes::from(
                Vec::<views::BootstrapAction>::new().abi_encode(),
            ));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let package = package_ending_on(counterfeit);
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        let sequence = verify_sequence_construction(
            &provider,
            &build(),
            &mut result,
            &package,
            &[SALT],
            &mut reviewed,
        )
        .await
        .unwrap();
        assert_eq!(sequence, None, "a counterfeit is not established");
        assert_eq!(result.errors, 1);
        assert!(reviewed.is_empty(), "and is not accounted for as a target");

        verify_derived_sequence(&provider, &mut result, &package, sequence, &BTreeMap::new()).await;
        assert_eq!(
            asserter.read_q().len(),
            3,
            "the counterfeit's stage lists must never be read"
        );
        assert_eq!(result.errors, 2);
        assert!(result.ensure_success().is_err());
    }

    /// The genuine sequence — built by the reviewed code over the reviewed migration and core
    /// registry — is established, and only then are its lists read and the bundle held against
    /// them.
    #[tokio::test]
    async fn the_genuine_sequence_is_established_and_then_consulted() {
        let genuine = canonical_create2_address(
            SALT,
            &sequence_code(),
            &constructor_args::registry_bootstrap_sequence(MIGRATION, CORE_TRANSITION),
        );
        let mut package = package_ending_on(genuine);
        let gate = action(
            "bootstrap completion gate",
            genuine,
            VALIDATE_APPLIED_SELECTOR.to_vec(),
        );
        let derived = [
            vec![action("pause", CAH, vec![0xaa, 0xbb, 0xcc, 0xdd])],
            derived_stage1(),
            vec![gate],
        ];
        package.stage0 = submitted_from(&derived[0]);
        package.stage1 = submitted_from(&derived[1]);
        package.stage2 = submitted_from(&derived[2]);

        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(&[0x60, 0x00]));
        for stage in &derived {
            asserter.push_success(&Bytes::from(stage.abi_encode()));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        let sequence = verify_sequence_construction(
            &provider,
            &build(),
            &mut result,
            &package,
            &[SALT],
            &mut reviewed,
        )
        .await
        .unwrap();
        assert_eq!(sequence, Some(genuine));
        assert_eq!(reviewed.len(), 1);

        let mut authorities = authorities();
        authorities.insert(genuine, "the bootstrap sequence".to_string());
        verify_derived_sequence(&provider, &mut result, &package, sequence, &authorities).await;
        assert!(asserter.read_q().is_empty(), "all three lists were read");
        assert_eq!(
            result.errors, 0,
            "a bundle that IS the derived sequence passes"
        );
    }

    /// A bootstrap package without a core transition has nothing to construct the sequence over:
    /// an error, not a sequence taken on trust.
    #[tokio::test]
    async fn a_sequence_without_a_core_transition_is_unverifiable() {
        let mut package = package_ending_on(Address::repeat_byte(0xCF));
        package.core_transition = None;
        let provider = ProviderBuilder::new().connect_mocked_client(Asserter::new());
        let mut result = VerificationResult::default();
        let sequence = verify_sequence_construction(
            &provider,
            &build(),
            &mut result,
            &package,
            &[SALT],
            &mut BTreeMap::new(),
        )
        .await
        .unwrap();
        assert_eq!(sequence, None);
        assert_eq!(result.errors, 1);
    }
}
