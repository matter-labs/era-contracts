//! Verification of a RECURRING registry-driven upgrade — the ordinary case, and the one every
//! upgrade after the bootstrap takes.
//!
//! # The two questions, kept apart
//!
//! **What does this upgrade do?** is answered by REVIEWING THE OBJECTS, not by reconstructing
//! them from calldata. An `EcosystemUpgradeOperation` pins the ecosystem inventory, the CTM-domain
//! infrastructure rows, the chain-version edge and the timer; a `CTMTransition` pins the release
//! pair and derives the facet cuts and the L2 plan from it. This module reads those objects live
//! and holds each against [`construction`](super::construction) — the reviewed creation code, run
//! on the manifest the object itself serves, must land at the object's address. That covers the
//! object's WHOLE state, so it keeps covering it when someone adds a derived field.
//!
//! **Does the signed transaction invoke the reviewed upgrade at the intended address?** is
//! answered by [`verify_stage_calls`] and is deliberately the whole of it: each stage must call
//! `EcosystemUpgradeExecutor.stageN(operation)` on the reviewed coordinator with the reviewed
//! operation. The operation's INTERNAL calls are NOT re-derived here — the coordinator and the
//! domain executors derive them on chain from the same pinned object, from audited code, and a
//! second derivation in this tool would be a second implementation to keep in sync. That
//! reconstruction is exactly what the registry model set out to remove.
//!
//! Everything else this module does is the part the objects cannot answer for themselves: that
//! authority is bound where the review says, that the live state the upgrade departs from is the
//! state it claims, and that the ecosystem is READY for it (the L2 bytecodes published, the timer
//! startable, no lifecycle already in flight).

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256};
use alloy::providers::Provider;
use alloy::sol_types::{SolCall, SolValue};

use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::verifiers::VerificationResult;

use super::construction::{expect_canonical_construction, ReviewedBuild};
use super::package::OperationPackage;
use super::provenance::{
    expect_code_identity, expect_code_present, expect_immutable_bearing_identity, tolerate,
    CodeIdentity, ImmutableValue,
};
use super::views::{
    BytecodesSupplierView, CTMReleaseView, CTMTransitionView, CTMUpgradeExecutorView,
    CommittedUpgradeView, CoreRegistryView, CoreUpgradeExecutorView, CtmView,
    EcosystemUpgradeExecutorView, EcosystemUpgradeOperationView, GovernanceUpgradeTimerView,
    ProxyAdminView, ProxyUpgradeRow,
};
use super::{format_semver, render_derived_payloads};

/// Verify a recurring registry-driven upgrade against the live L1 it targets.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    package: &OperationPackage,
    expected_governance_owner: Option<Address>,
    salts: &[B256],
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    // The set of addresses this run establishes as reviewed, for the calldata check below.
    let mut reviewed: BTreeMap<Address, String> = BTreeMap::new();

    result.print_info("== Package ==");
    result.report_ok(&format!(
        "a recurring registry-driven upgrade on CTM section [{}]: operation {}, driven through \
         coordinator {}",
        package.ctm_key, package.operation, package.coordinator
    ));

    // ── 1. The operation, and the manifest its address commits to ──
    result.print_info("\n== Object provenance ==");
    expect_code_identity(
        provider,
        identity,
        result,
        "the operation",
        package.operation,
        "EcosystemUpgradeOperation",
    )
    .await?;
    let operation = EcosystemUpgradeOperationView::new(package.operation, provider);
    let manifest = match operation.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the object at {} does not answer `getManifest()` ({e}): it is not an \
                 EcosystemUpgradeOperation, so nothing further about this package can be verified",
                package.operation
            ));
            return Ok(());
        }
    };

    result.print_info("\n== Object construction ==");
    if expect_canonical_construction(
        build,
        result,
        "the operation",
        package.operation,
        "EcosystemUpgradeOperation",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(package.operation, "the operation".to_string());
    }

    let transition = non_zero(manifest.transition);
    cross_check(
        result,
        "ctm_transition_addr",
        package.reported_transition,
        transition,
        "the transition",
    );
    let transition_manifest = match transition {
        Some(address) => {
            verify_transition(provider, identity, build, result, address, salts, &mut reviewed)
                .await?
        }
        None => {
            result.report_ok(
                "the operation carries no transition: it moves no chain version, so its CTM leg \
                 is infrastructure only",
            );
            None
        }
    };

    let core_registry = non_zero(manifest.coreRegistry);
    cross_check(
        result,
        "core_registry_addr",
        package.reported_core_registry,
        core_registry,
        "the core registry",
    );
    let core_rows = match core_registry {
        Some(address) => {
            verify_core_registry(provider, identity, build, result, address, salts, &mut reviewed)
                .await?
        }
        None => {
            result.report_ok("the operation carries no core registry: it upgrades no shared singletons");
            Vec::new()
        }
    };

    // The three changes are each optional, but the object refuses to be all three at once
    // (`OperationChangesNothing`). Naming what this one actually carries is what a reviewer
    // reads first.
    let ctm_rows: Vec<ProxyUpgradeRow> = manifest
        .ctmInfrastructure
        .iter()
        .filter(|row| !row.implNew.is_zero())
        .cloned()
        .collect();
    result.print_info(&format!(
        "  this operation carries: {} CTM-domain infrastructure row(s), {} ecosystem row(s), and \
         {}",
        ctm_rows.len(),
        core_rows.len(),
        match transition {
            Some(address) => format!("the chain-version transition {address}"),
            None => "no chain-version transition".to_string(),
        }
    ));

    // ── 2. Authority: the coordinator, the domains it drives, and the owner they answer to ──
    result.print_info("\n== Bound authority ==");
    expect_code_identity(
        provider,
        identity,
        result,
        "the coordinator",
        package.coordinator,
        "EcosystemUpgradeExecutor",
    )
    .await?;
    let coordinator = EcosystemUpgradeExecutorView::new(package.coordinator, provider);
    let Some(core_executor_addr) = tolerate(
        coordinator.CORE_EXECUTOR().call().await,
        result,
        "the coordinator's CORE_EXECUTOR",
    ) else {
        return Ok(());
    };
    let Some(ctm_executor_addr) = tolerate(
        coordinator.ctmExecutor().call().await,
        result,
        "the coordinator's bound CTM executor",
    ) else {
        return Ok(());
    };
    if ctm_executor_addr.is_zero() {
        result.report_error(
            "the coordinator has no bound CTM executor: `stage0` reverts before it reserves \
             anything, so this upgrade could not start",
        );
        return Ok(());
    }
    cross_check(
        result,
        "ctm_upgrade_executor_addr",
        package.reported_ctm_executor,
        Some(ctm_executor_addr),
        "the CTM executor",
    );

    // The CTM executor's bindings ARE its identity: it sets them as constructor immutables, so
    // its runtime code cannot hash to the reviewed artifact (whose immutable slots are zero).
    let ctm_executor = CTMUpgradeExecutorView::new(ctm_executor_addr, provider);
    let Some(ctm_addr) = tolerate(
        ctm_executor.CHAIN_TYPE_MANAGER().call().await,
        result,
        "the CTM executor's bound CTM",
    ) else {
        return Ok(());
    };
    let Some(ctm_admin_addr) = tolerate(
        ctm_executor.CTM_PROXY_ADMIN().call().await,
        result,
        "the CTM executor's bound ProxyAdmin",
    ) else {
        return Ok(());
    };
    // An operation names no CTM — the binding is the executor's immutable — so the reviewer is
    // told which CTM this upgrade lands on rather than left to infer it.
    result.report_ok(&format!(
        "the upgrade lands on CTM {ctm_addr}, under ProxyAdmin {ctm_admin_addr}"
    ));
    expect_immutable_bearing_identity(
        provider,
        identity,
        result,
        "the bound CTM upgrade executor",
        ctm_executor_addr,
        "CTMUpgradeExecutor",
        &[
            ImmutableValue::new("CHAIN_TYPE_MANAGER", ctm_addr, ctm_addr),
            ImmutableValue::new("CTM_PROXY_ADMIN", ctm_admin_addr, ctm_admin_addr),
        ],
    )
    .await?;
    expect_code_identity(
        provider,
        identity,
        result,
        "the core executor",
        core_executor_addr,
        "CoreUpgradeExecutor",
    )
    .await?;
    let core_executor = CoreUpgradeExecutorView::new(core_executor_addr, provider);
    let Some(core_admin_addr) = tolerate(
        core_executor.PROXY_ADMIN().call().await,
        result,
        "the core executor's PROXY_ADMIN",
    ) else {
        return Ok(());
    };

    // Both domains must already answer to THIS coordinator, or its stage callbacks revert.
    for (label, bound) in [
        (
            "the CTM executor",
            tolerate(
                ctm_executor.coordinator().call().await,
                result,
                "the CTM executor's coordinator",
            ),
        ),
        (
            "the core executor",
            tolerate(
                core_executor.coordinator().call().await,
                result,
                "the core executor's coordinator",
            ),
        ),
    ] {
        match bound {
            Some(bound) if bound == package.coordinator => {
                result.report_ok(&format!("{label} answers to the reviewed coordinator"))
            }
            Some(bound) => result.report_error(&format!(
                "{label} answers to coordinator {bound}, not the reviewed {}: its lifecycle \
                 callbacks would revert",
                package.coordinator
            )),
            None => {}
        }
    }

    verify_governance_owner(
        provider,
        result,
        expected_governance_owner,
        package.coordinator,
        core_executor_addr,
        ctm_executor_addr,
    )
    .await;

    // The authority each domain must already HOLD. Unlike a bootstrap, a recurring upgrade hands
    // nothing over — it executes on authority the previous edge established, so authority that
    // has since drifted is a finding now rather than a revert mid-bundle.
    expect_owned_by(
        provider,
        result,
        "the CTM",
        ctm_addr,
        ctm_executor_addr,
        "the CTM executor",
    )
    .await;
    expect_owned_by(
        provider,
        result,
        "the CTM-domain ProxyAdmin",
        ctm_admin_addr,
        ctm_executor_addr,
        "the CTM executor",
    )
    .await;
    expect_owned_by(
        provider,
        result,
        "the ecosystem ProxyAdmin",
        core_admin_addr,
        core_executor_addr,
        "the core executor",
    )
    .await;
    let Some(ctm_pending_owner) = tolerate(
        CtmView::new(ctm_addr, provider).pendingOwner().call().await,
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
             could take the CTM out from under the executor this upgrade runs through"
        ));
    }

    // No lifecycle in flight, on the coordinator or on either domain: `stage0` refuses over a
    // reservation, so an upgrade prepared on top of one could never execute.
    for (label, reserved) in [
        (
            "the coordinator",
            tolerate(
                coordinator.pendingOperation().call().await,
                result,
                "the coordinator's pendingOperation()",
            ),
        ),
        (
            "the CTM executor",
            tolerate(
                ctm_executor.activeOperation().call().await,
                result,
                "the CTM executor's activeOperation()",
            ),
        ),
        (
            "the core executor",
            tolerate(
                core_executor.activeOperation().call().await,
                result,
                "the core executor's activeOperation()",
            ),
        ),
    ] {
        match reserved {
            Some(reserved) if reserved.is_zero() => {
                result.report_ok(&format!("{label} holds no reservation"))
            }
            Some(reserved) => result.report_error(&format!(
                "{label} is already reserved for operation {reserved}: this upgrade's stage 0 \
                 would revert, and the ecosystem is mid-lifecycle"
            )),
            None => {}
        }
    }

    // ── 3. The state the upgrade departs from ──
    result.print_info("\n== Departing state ==");
    let ctm = CtmView::new(ctm_addr, provider);
    if let Some(transition_manifest) = &transition_manifest {
        let Some(live_version) = tolerate(
            ctm.protocolVersion().call().await,
            result,
            "the CTM's live protocol version",
        ) else {
            return Ok(());
        };
        if live_version == transition_manifest.oldProtocolVersion {
            result.report_ok(&format!(
                "the CTM is at the transition's departing version {}",
                format_semver(live_version)
            ));
        } else {
            result.report_error(&format!(
                "the CTM is at version {} but the transition departs from {}: the version edge \
                 is refused on chain",
                format_semver(live_version),
                format_semver(transition_manifest.oldProtocolVersion)
            ));
        }
        result.report_ok(&format!(
            "the transition moves chains to {}",
            format_semver(transition_manifest.newProtocolVersion)
        ));

        let Some(live_release) = tolerate(
            ctm.currentRelease().call().await,
            result,
            "the CTM's live currentRelease()",
        ) else {
            return Ok(());
        };
        if live_release == transition_manifest.fromRelease {
            result.report_ok(&format!(
                "the transition departs from the release the CTM is actually on ({live_release})"
            ));
        } else {
            result.report_error(&format!(
                "the transition departs from release {} but the CTM is on {live_release}: the \
                 release edge is refused on chain, and the two describe different starting points",
                transition_manifest.fromRelease
            ));
        }
    }

    verify_rows(
        provider,
        result,
        "CTM-domain row",
        &ctm_rows,
        ctm_admin_addr,
    )
    .await?;
    verify_rows(provider, result, "ecosystem row", &core_rows, core_admin_addr).await?;

    // ── 4. Readiness: the things stage 0 and stage 1 require that no object can assert ──
    result.print_info("\n== Readiness ==");
    verify_timer(provider, identity, result, manifest.timer, package.coordinator).await?;
    if let Some(transition_addr) = transition {
        verify_bytecodes_published(provider, result, &ctm, transition_addr).await?;
    }

    // ── 5. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    verify_stage_calls(package, result);

    // ── 6. The calls no object describes ──
    if package.external_actions.is_empty() {
        result.report_ok(
            "the prepare declared no external actions: this upgrade is entirely described by the \
             operation",
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

/// THE question about the signed transaction, and the whole of it.
///
/// Governance signs three calls and nothing derived: `coordinator.stageN(operation)` for
/// N in 0..=2. Each is re-ENCODED here from the reviewed coordinator and the reviewed operation
/// and compared byte for byte, so a bundle naming a different operation, a different coordinator,
/// or the stages out of order is a finding rather than a passing shape check.
///
/// Every other call in a stage must be a declared external action. Those carry authority the
/// upgrade objects do not describe, so they are the reviewer's to read — but a call that is
/// neither the stage call nor a declared action is an ERROR: it is how a bundle would smuggle an
/// unreviewed instruction past a reviewer reading only the operation.
fn verify_stage_calls(package: &OperationPackage, result: &mut VerificationResult) {
    let expected = [
        EcosystemUpgradeExecutorView::stage0Call {
            _operation: package.operation,
        }
        .abi_encode(),
        EcosystemUpgradeExecutorView::stage1Call {
            _operation: package.operation,
        }
        .abi_encode(),
        EcosystemUpgradeExecutorView::stage2Call {
            _operation: package.operation,
        }
        .abi_encode(),
    ];
    let stages = [&package.stage0, &package.stage1, &package.stage2];

    for (stage, (calls, expected)) in stages.iter().zip(expected.iter()).enumerate() {
        let matches: Vec<&GovernanceCall> = calls
            .iter()
            .filter(|call| {
                call.target == package.coordinator && call.value.is_zero() && call.data == *expected
            })
            .collect();
        match matches.len() {
            1 => result.report_ok(&format!(
                "stage {stage} calls stage{stage}({}) on the reviewed coordinator {}",
                package.operation, package.coordinator
            )),
            0 => result.report_error(&format!(
                "stage {stage} never calls stage{stage}({}) on the reviewed coordinator {}: the \
                 bundle governance would sign does not drive the reviewed upgrade",
                package.operation, package.coordinator
            )),
            n => result.report_error(&format!(
                "stage {stage} calls stage{stage}({}) {n} times: the second would revert, and a \
                 duplicated lifecycle call is not a bundle the prepare produces",
                package.operation
            )),
        }

        for call in calls.iter() {
            if call.target == package.coordinator && call.data == *expected {
                continue;
            }
            let declared = package
                .external_actions
                .iter()
                .any(|action| action.phase == stage.to_string() && action.is_call(call));
            if !declared {
                result.report_error(&format!(
                    "stage {stage} calls {} (selector 0x{}), which is neither this upgrade's \
                     lifecycle call nor a declared external action: the bundle carries an \
                     instruction no part of this review accounts for",
                    call.target,
                    alloy::hex::encode(call.data.get(..4).unwrap_or_default())
                ));
            }
        }
    }
}

/// The transition's provenance, construction and derived payload.
#[allow(clippy::too_many_arguments)]
async fn verify_transition<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    transition: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Option<super::views::TransitionManifest>> {
    expect_code_identity(
        provider,
        identity,
        result,
        "the transition the operation carries",
        transition,
        "CTMTransition",
    )
    .await?;
    let view = CTMTransitionView::new(transition, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the transition at {transition} does not answer `getManifest()` ({e}): its \
                 construction cannot be verified"
            ));
            return Ok(None);
        }
    };
    if expect_canonical_construction(
        build,
        result,
        "the transition the operation carries",
        transition,
        "CTMTransition",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(
            transition,
            "the transition the operation carries".to_string(),
        );
    }

    // The arriving release is a member the transition NAMES, so its own construction is verified
    // separately — the transition's address commits to the release's ADDRESS, not to its state.
    verify_release(
        provider,
        identity,
        build,
        result,
        "the release the transition installs",
        manifest.newRelease,
        salts,
        reviewed,
    )
    .await?;
    expect_code_identity(
        provider,
        identity,
        result,
        "the release the transition departs from",
        manifest.fromRelease,
        "CTMRelease",
    )
    .await?;
    expect_code_present(
        provider,
        result,
        "the transition's upgradeEngine",
        manifest.upgradeEngine,
    )
    .await?;
    if !manifest.l2Plan.delegateComposer.is_zero() {
        expect_code_present(
            provider,
            result,
            "the transition's l2Plan.delegateComposer",
            manifest.l2Plan.delegateComposer,
        )
        .await?;
    }

    render_facet_cuts(&view, result, transition).await;
    render_derived_payloads(provider, result, transition).await;
    Ok(Some(manifest))
}

/// A release's provenance and construction, re-derived from the manifest it serves.
#[allow(clippy::too_many_arguments)]
async fn verify_release<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    release: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<()> {
    expect_code_identity(provider, identity, result, label, release, "CTMRelease").await?;
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
    Ok(())
}

/// The core registry's provenance and construction, plus the rows it pins.
#[allow(clippy::too_many_arguments)]
async fn verify_core_registry<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    core_registry: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Vec<ProxyUpgradeRow>> {
    expect_code_identity(
        provider,
        identity,
        result,
        "the core registry",
        core_registry,
        "CoreRegistry",
    )
    .await?;
    let view = CoreRegistryView::new(core_registry, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the core registry at {core_registry} does not answer `getManifest()` ({e}): its \
                 construction cannot be verified"
            ));
            return Ok(Vec::new());
        }
    };
    if expect_canonical_construction(
        build,
        result,
        "the core registry",
        core_registry,
        "CoreRegistry",
        &manifest.abi_encode(),
        salts,
    ) {
        reviewed.insert(core_registry, "the core registry".to_string());
    }
    Ok(manifest
        .proxyUpgrades
        .into_iter()
        .filter(|row| !row.implNew.is_zero())
        .collect())
}

/// Each participating row must depart from the implementation that is LIVE, read through the
/// admin the row itself names (or the applying executor's bound admin when it names none — the
/// same resolution `ProxyUpgradeRowLib.adminOf` performs).
///
/// A row at an unexpected implementation reverts the whole stage on chain, so a mismatch here is
/// an upgrade that cannot execute, not a cosmetic drift.
async fn verify_rows<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    kind: &str,
    rows: &[ProxyUpgradeRow],
    default_admin: Address,
) -> anyhow::Result<()> {
    for (i, row) in rows.iter().enumerate() {
        let admin = if row.admin.is_zero() {
            default_admin
        } else {
            row.admin
        };
        let label = format!("{kind} {i} ({})", row.proxy);
        let Some(live_impl) = tolerate(
            ProxyAdminView::new(admin, provider)
                .getProxyImplementation(row.proxy)
                .call()
                .await,
            result,
            &format!("{label}: the live implementation of {} under {admin}", row.proxy),
        ) else {
            continue;
        };
        if live_impl == row.expectedOldImpl {
            result.report_ok(&format!("{label} departs from the live implementation"));
        } else if live_impl == row.implNew {
            // Idempotence, which the row semantics allow: a proxy already at `implNew` is skipped.
            // Worth a finding anyway — it means part of this upgrade has already happened.
            result.report_warn(&format!(
                "{label} is ALREADY at its new implementation {}: the row is a no-op, so part of \
                 this upgrade has already been applied",
                row.implNew
            ));
        } else {
            result.report_error(&format!(
                "{label} expects to depart from {} but {live_impl} is live",
                row.expectedOldImpl
            ));
        }
        expect_code_present(provider, result, &format!("{label} implNew"), row.implNew).await?;
        if row.admin != Address::ZERO {
            result.report_warn(&format!(
                "{label} names a FOREIGN ProxyAdmin {}: the executor applies it only if it owns \
                 that admin, otherwise the row is left to that administrator and stage 2 still \
                 requires it applied",
                row.admin
            ));
        }
    }
    Ok(())
}

/// The timer gating stage 1.
///
/// `TIMER_GOVERNANCE` is a constructor-set immutable, so the timer's runtime code cannot hash to
/// its artifact — which is why that value IS the timer's identity check. For a recurring upgrade
/// it must be the COORDINATOR: `EcosystemUpgradeExecutor.stage0` starts the timer itself, and
/// `startTimer` is `onlyTimerAdmin`. (A bootstrap's timer is governed by governance instead,
/// because at that point no executor holds the domain yet.)
async fn verify_timer<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    result: &mut VerificationResult,
    timer: Address,
    coordinator: Address,
) -> anyhow::Result<()> {
    let view = GovernanceUpgradeTimerView::new(timer, provider);
    let Some(timer_governance) = tolerate(
        view.TIMER_GOVERNANCE().call().await,
        result,
        "the timer's TIMER_GOVERNANCE()",
    ) else {
        return Ok(());
    };
    expect_immutable_bearing_identity(
        provider,
        identity,
        result,
        "the upgrade timer",
        timer,
        "GovernanceUpgradeTimer",
        &[ImmutableValue::new(
            "TIMER_GOVERNANCE",
            timer_governance,
            coordinator,
        )],
    )
    .await?;
    if timer_governance != coordinator {
        result.report_error(&format!(
            "the timer is governed by {timer_governance}, not the coordinator {coordinator} that \
             starts it: stage 0 would revert in `startTimer`"
        ));
    }

    let Some(deadline) = tolerate(
        view.deadline().call().await,
        result,
        "the timer's deadline()",
    ) else {
        return Ok(());
    };
    if deadline.is_zero() {
        result.report_ok("the timer is un-started, so stage 0 can start it");
    } else {
        result.report_error(&format!(
            "the timer is already started (deadline {deadline}): `startTimer` refuses a second \
             start, so this upgrade's stage 0 would revert"
        ));
    }
    Ok(())
}

/// Every bytecode the transition's L2 transaction depends on must ALREADY be published on the
/// CTM's supplier: `applyOperation` requires it, and an unpublished dependency fails the committed
/// edge on every chain's L2 leg rather than on L1.
///
/// This is a READINESS check and nothing more — it says the upgrade can execute, never that any
/// value is safe.
async fn verify_bytecodes_published<P: Provider>(
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
    let mut unpublished = 0usize;
    for hash in &plan.factoryDepHashes {
        let hash: B256 = (*hash).into();
        let Some(block) = tolerate(
            supplier.evmPublishingBlock(hash).call().await,
            result,
            &format!("the supplier's publication block for {hash}"),
        ) else {
            continue;
        };
        if block.is_zero() {
            unpublished += 1;
            result.report_error(&format!(
                "the L2 bytecode {hash} is NOT published on supplier {supplier_addr}: stage 1 \
                 reverts in `L2PlanLib.requirePublished`"
            ));
        }
    }
    if unpublished == 0 {
        result.report_ok(&format!(
            "all {} L2 factory dependencies are published on supplier {supplier_addr}",
            plan.factoryDepHashes.len()
        ));
    }
    Ok(())
}

/// The governance address the whole lifecycle answers to, held against the review.
async fn verify_governance_owner<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    expected: Option<Address>,
    coordinator: Address,
    core_executor: Address,
    ctm_executor: Address,
) {
    let owners = [
        (
            "the coordinator",
            tolerate(
                EcosystemUpgradeExecutorView::new(coordinator, provider)
                    .owner()
                    .call()
                    .await,
                result,
                "the coordinator's owner",
            ),
        ),
        (
            "the core executor",
            tolerate(
                CoreUpgradeExecutorView::new(core_executor, provider)
                    .owner()
                    .call()
                    .await,
                result,
                "the core executor's owner",
            ),
        ),
        (
            "the CTM executor",
            tolerate(
                CTMUpgradeExecutorView::new(ctm_executor, provider)
                    .owner()
                    .call()
                    .await,
                result,
                "the CTM executor's owner",
            ),
        ),
    ];

    // The coordinator's owner is the address that signs all three stages, so every domain must
    // answer to it: one lifecycle under two owners cannot complete.
    let Some(Some(governance)) = owners.first().map(|(_, owner)| *owner) else {
        return;
    };
    for (label, owner) in owners.iter().skip(1) {
        match owner {
            Some(owner) if *owner == governance => result.report_ok(&format!(
                "{label} is owned by the same governance as the coordinator ({owner})"
            )),
            Some(owner) => result.report_error(&format!(
                "{label} is owned by {owner}, not by the coordinator's owner {governance}: one \
                 lifecycle would answer to two owners"
            )),
            None => {}
        }
    }

    match expected {
        Some(expected) if expected == governance => result.report_ok(&format!(
            "the lifecycle is owned by the reviewed governance address {expected}"
        )),
        Some(expected) => result.report_error(&format!(
            "the lifecycle is owned by {governance} but the reviewed governance address is \
             {expected}: this upgrade would be driven by someone other than the reviewed owner"
        )),
        None => result.report_warn(&format!(
            "no --expected-governance-owner supplied: the lifecycle owner {governance} is \
             reported but unverified against the review"
        )),
    }
}

/// An `Ownable` whose owner the review fixes.
async fn expect_owned_by<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    subject: Address,
    expected: Address,
    expected_label: &str,
) {
    let Some(owner) = tolerate(
        ProxyAdminView::new(subject, provider).owner().call().await,
        result,
        &format!("{label}'s owner"),
    ) else {
        return;
    };
    if owner == expected {
        result.report_ok(&format!("{label} is owned by {expected_label} ({expected})"));
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
/// the manifest is what executes. A disagreement means the reviewer reviewed a different object
/// from the one governance would drive.
fn cross_check(
    result: &mut VerificationResult,
    field: &str,
    reported: Option<Address>,
    actual: Option<Address>,
    what: &str,
) {
    match (reported, actual) {
        (Some(reported), Some(actual)) if reported == actual => {
            result.report_ok(&format!("the package's reported {field} is {what} that executes"))
        }
        (Some(reported), Some(actual)) => result.report_error(&format!(
            "the package reports {field} {reported} but the operation pins {actual} as {what}: \
             the summary a reviewer reads describes a different object from the executing one"
        )),
        (Some(reported), None) => result.report_error(&format!(
            "the package reports {field} {reported} but the operation carries no {what} at all"
        )),
        (None, Some(actual)) => result.report_warn(&format!(
            "the package does not report {field}, so {what} ({actual}) is known only from the \
             operation's own manifest"
        )),
        (None, None) => {}
    }
}

fn non_zero(address: Address) -> Option<Address> {
    (!address.is_zero()).then_some(address)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::U256;

    use crate::common::external_actions::ExternalAction;

    const OPERATION: Address = Address::repeat_byte(0xA0);
    const COORDINATOR: Address = Address::repeat_byte(0xC0);

    fn stage_call(stage: u8, coordinator: Address, operation: Address) -> GovernanceCall {
        let data = match stage {
            0 => EcosystemUpgradeExecutorView::stage0Call {
                _operation: operation,
            }
            .abi_encode(),
            1 => EcosystemUpgradeExecutorView::stage1Call {
                _operation: operation,
            }
            .abi_encode(),
            _ => EcosystemUpgradeExecutorView::stage2Call {
                _operation: operation,
            }
            .abi_encode(),
        };
        GovernanceCall {
            target: coordinator,
            value: U256::ZERO,
            data,
        }
    }

    fn package(
        stage0: Vec<GovernanceCall>,
        stage1: Vec<GovernanceCall>,
        stage2: Vec<GovernanceCall>,
        external_actions: Vec<ExternalAction>,
    ) -> OperationPackage {
        OperationPackage {
            operation: OPERATION,
            coordinator: COORDINATOR,
            ctm_key: "zksync_os".to_string(),
            reported_transition: None,
            reported_core_registry: None,
            reported_ctm_executor: None,
            stage0,
            stage1,
            stage2,
            external_actions,
            create2_salts: Vec::new(),
        }
    }

    fn well_formed() -> OperationPackage {
        package(
            vec![stage_call(0, COORDINATOR, OPERATION)],
            vec![stage_call(1, COORDINATOR, OPERATION)],
            vec![stage_call(2, COORDINATOR, OPERATION)],
            Vec::new(),
        )
    }

    #[test]
    fn the_three_lifecycle_calls_pass() {
        let mut result = VerificationResult::default();
        verify_stage_calls(&well_formed(), &mut result);
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
    }

    /// The selectors the check rests on must be the coordinator's real ones, so a signature
    /// change is caught here rather than by a package that silently stops matching.
    #[test]
    fn the_stage_selectors_are_the_coordinators() {
        for (stage, sig) in [
            (0u8, &b"stage0(address)"[..]),
            (1, &b"stage1(address)"[..]),
            (2, &b"stage2(address)"[..]),
        ] {
            let call = stage_call(stage, COORDINATOR, OPERATION);
            assert_eq!(
                &call.data[..4],
                &alloy::primitives::keccak256(sig)[..4],
                "selector drifted for stage {stage}"
            );
        }
    }

    /// THE substitution this check exists to catch: a bundle that drives a DIFFERENT operation
    /// through the reviewed coordinator. Everything about the shape is right; only the address
    /// the reviewer approved is missing.
    #[test]
    fn a_bundle_driving_a_different_operation_fails() {
        let impostor = Address::repeat_byte(0xBB);
        let mut result = VerificationResult::default();
        verify_stage_calls(
            &package(
                vec![stage_call(0, COORDINATOR, impostor)],
                vec![stage_call(1, COORDINATOR, impostor)],
                vec![stage_call(2, COORDINATOR, impostor)],
                Vec::new(),
            ),
            &mut result,
        );
        // Three stages, each missing its lifecycle call and carrying an undeclared one.
        assert_eq!(result.errors, 6);
        assert!(result.ensure_success().is_err());
    }

    /// The same upgrade driven through a coordinator the review did not approve: the operation is
    /// right, the place it executes is not.
    #[test]
    fn a_bundle_driving_the_operation_through_another_coordinator_fails() {
        let impostor = Address::repeat_byte(0xDD);
        let mut result = VerificationResult::default();
        verify_stage_calls(
            &package(
                vec![stage_call(0, impostor, OPERATION)],
                vec![stage_call(1, impostor, OPERATION)],
                vec![stage_call(2, impostor, OPERATION)],
                Vec::new(),
            ),
            &mut result,
        );
        assert_eq!(result.errors, 6);
    }

    /// Stages out of order: each stage must carry ITS OWN lifecycle call, or the coordinator's
    /// `_requirePending` gate would refuse the bundle mid-flight.
    #[test]
    fn stages_out_of_order_fail() {
        let mut result = VerificationResult::default();
        verify_stage_calls(
            &package(
                vec![stage_call(1, COORDINATOR, OPERATION)],
                vec![stage_call(0, COORDINATOR, OPERATION)],
                vec![stage_call(2, COORDINATOR, OPERATION)],
                Vec::new(),
            ),
            &mut result,
        );
        // Stages 0 and 1 each miss their own call and carry an unaccounted one.
        assert_eq!(result.errors, 4);
    }

    /// An extra call nobody declared rides along with three perfectly good lifecycle calls. It
    /// must fail the run, not be reported as a note beside a successful review.
    #[test]
    fn an_undeclared_extra_call_fails_the_run() {
        let mut pkg = well_formed();
        pkg.stage1.push(GovernanceCall {
            target: Address::repeat_byte(0xEE),
            value: U256::ZERO,
            data: vec![0xde, 0xad, 0xbe, 0xef],
        });
        let mut result = VerificationResult::default();
        verify_stage_calls(&pkg, &mut result);
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }

    /// The same extra call, DECLARED: an independently authorized action rides along and is the
    /// reviewer's to read, so it passes the calldata check and is printed rather than flagged.
    #[test]
    fn a_declared_external_action_rides_along() {
        let extra = GovernanceCall {
            target: Address::repeat_byte(0xEE),
            value: U256::ZERO,
            data: vec![0xde, 0xad, 0xbe, 0xef],
        };
        let mut pkg = well_formed();
        pkg.stage1.push(extra.clone());
        pkg.external_actions
            .push(ExternalAction::for_stage(1, "an admin hop", "governance", &extra));
        let mut result = VerificationResult::default();
        verify_stage_calls(&pkg, &mut result);
        assert_eq!(result.errors, 0);
    }

    /// A declared action counts only for the phase it was declared in: a stage-2 declaration
    /// must not excuse the same call appearing in stage 1.
    #[test]
    fn a_declaration_does_not_carry_across_stages() {
        let extra = GovernanceCall {
            target: Address::repeat_byte(0xEE),
            value: U256::ZERO,
            data: vec![0xde, 0xad, 0xbe, 0xef],
        };
        let mut pkg = well_formed();
        pkg.stage1.push(extra.clone());
        pkg.external_actions
            .push(ExternalAction::for_stage(2, "an admin hop", "governance", &extra));
        let mut result = VerificationResult::default();
        verify_stage_calls(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    /// A stage that drives the reviewed upgrade TWICE: the second call reverts on chain, so a
    /// bundle carrying it is not one the prepare produced.
    #[test]
    fn a_duplicated_lifecycle_call_fails() {
        let mut pkg = well_formed();
        pkg.stage0.push(stage_call(0, COORDINATOR, OPERATION));
        let mut result = VerificationResult::default();
        verify_stage_calls(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    /// A lifecycle call carrying value is not the call the merge derives, and the coordinator's
    /// stages are not payable.
    #[test]
    fn a_lifecycle_call_carrying_value_is_not_the_reviewed_call() {
        let mut pkg = well_formed();
        pkg.stage0[0].value = U256::from(1);
        let mut result = VerificationResult::default();
        verify_stage_calls(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_missing_stage_is_reported_per_stage() {
        let mut pkg = well_formed();
        pkg.stage2.clear();
        let mut result = VerificationResult::default();
        verify_stage_calls(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_reported_field_disagreeing_with_the_manifest_is_an_error() {
        let mut result = VerificationResult::default();
        cross_check(
            &mut result,
            "ctm_transition_addr",
            Some(Address::repeat_byte(0x11)),
            Some(Address::repeat_byte(0x22)),
            "the transition",
        );
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_reported_field_the_operation_does_not_carry_is_an_error() {
        let mut result = VerificationResult::default();
        cross_check(
            &mut result,
            "core_registry_addr",
            Some(Address::repeat_byte(0x11)),
            None,
            "the core registry",
        );
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn an_agreeing_report_passes_and_an_absent_one_warns() {
        let mut result = VerificationResult::default();
        let same = Address::repeat_byte(0x11);
        cross_check(&mut result, "f", Some(same), Some(same), "the transition");
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
        cross_check(&mut result, "f", None, Some(same), "the transition");
        assert_eq!(result.warnings, 1);
        cross_check(&mut result, "f", None, None, "the transition");
        assert_eq!(result.warnings, 1);
    }
}
