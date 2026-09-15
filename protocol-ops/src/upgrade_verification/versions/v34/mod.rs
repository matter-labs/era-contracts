//! Verification of a v34 registry-bootstrap package.
//!
//! # What this replaces
//!
//! The v31 verifier re-derived ~60 governance calls and cross-checked each against live state,
//! because the reviewable artifact WAS the calldata. A registry-driven package inverts that:
//! governance executes a handful of calls naming write-once objects, and everything executable
//! is derived on-chain from those objects at execution time. So this verifier answers a
//! different question — not "is this calldata what the scripts would produce?" but:
//!
//!   1. Does every object run the code the reviewed commit produces? (`provenance`)
//!   2. Does every contract the manifest names exist, and does each object-type ANCHOR hold
//!      the reviewed commit's codehash for the object type it admits?
//!   3. Is authority bound as the manifest claims, and to the expected governance owner?
//!   4. Does every proxy row depart from the implementation that is actually live?
//!   5. Is the edge un-executed, and does the calldata contain only the expected calls?
//!
//! Question 2 is deliberately NOT "does the manifest's own fingerprint of a member match that
//! member's code": the manifest author supplies both halves of such a pair, so it can only ever
//! agree with itself. Every comparison here is against the reviewed commit or against live
//! state the package does not control.
//!
//! # What it deliberately does not do
//!
//! It does not re-derive facet cuts, L2 transactions or proposals. Those are derived on-chain
//! from the release pair, and `TransitionDerivationLib` is audited code — re-deriving them here
//! would be a second implementation to keep in sync, which is exactly what the registry model
//! set out to remove. It also does not call the objects' own `validate()`: that runs against
//! post-handover state (it requires the migration to already hold both ownerships), so
//! pre-execution it reverts by design and tells a reviewer nothing.

use alloy::primitives::{Address, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolCall;

use crate::common::ethereum::get_provider;
use crate::upgrade_verification::verifiers::VerificationResult;

pub(crate) mod package;
pub(crate) mod provenance;
pub(crate) mod views;

use package::{
    BootstrapPackage, APPLY_L1_UPGRADE_SELECTOR, MIGRATE_SELECTOR, PAUSE_MIGRATION_SELECTOR,
    SET_COORDINATOR_SELECTOR, TRANSFER_OWNERSHIP_SELECTOR, UNPAUSE_MIGRATION_SELECTOR,
    VALIDATE_APPLIED_SELECTOR,
};
use provenance::{
    expect_code_identity, expect_code_present, expect_immutable_bearing_identity, tolerate,
    CodeIdentity, ImmutableValue,
};
use views::{
    CTMUpgradeExecutorView, CoreRegistryView, CoreUpgradeExecutorView, CtmForBootstrapView,
    EcosystemUpgradeExecutorView, GovernanceUpgradeTimerView,
    GovernanceUpgradeTimerView::GovernanceUpgradeTimerViewInstance, ProxyAdminView,
    RegistryBootstrapMigrationView,
};

/// Verify a v34 bootstrap package against the live L1 it targets.
///
/// `expected_governance_owner` is the reviewed value the CTM executor must end up owned by —
/// the single most consequential field in the manifest, because an executor bound to the wrong
/// owner hands the CTM domain to that owner permanently.
pub(crate) async fn verify(
    ecosystem_toml: &std::path::Path,
    l1_rpc_url: &str,
    expected_governance_owner: Option<Address>,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let package = BootstrapPackage::load(ecosystem_toml)?;
    let provider = get_provider(l1_rpc_url)?;
    let identity = CodeIdentity::from_local_hashes()?;

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
        &provider,
        &identity,
        result,
        "the bootstrap migration",
        package.migration,
        "RegistryBootstrapMigration",
    )
    .await?;

    let migration = RegistryBootstrapMigrationView::new(package.migration, &provider);
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
        &provider,
        &identity,
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
        &provider,
        result,
        "manifest.upgradeEngine",
        manifest.upgradeEngine,
    )
    .await?;
    if !manifest.l2Plan.delegateComposer.is_zero() {
        expect_code_present(
            &provider,
            result,
            "manifest.l2Plan.delegateComposer",
            manifest.l2Plan.delegateComposer,
        )
        .await?;
    }

    // ── 3. Authority: the binding, and the owner it lands on ──
    result.print_info("\n== Bound authority ==");
    let executor = CTMUpgradeExecutorView::new(manifest.ctmExecutor, &provider);
    // The executor sets its bindings as constructor immutables, so its runtime code cannot hash
    // to the reviewed artifact (whose immutable slots are zero). Identity therefore rests on
    // those VALUES — read back here and held against the manifest, and, for the transition
    // anchor, against the reviewed commit's own `CTMTransition` bytecode rather than against
    // anything the package supplied.
    let bound_ctm = tolerate(
        executor.CHAIN_TYPE_MANAGER().call().await,
        result,
        "the executor's bound CTM",
    );
    let bound_admin = tolerate(
        executor.CTM_PROXY_ADMIN().call().await,
        result,
        "the executor's bound ProxyAdmin",
    );
    let transition_anchor = tolerate(
        executor.TRANSITION_CODEHASH().call().await,
        result,
        "the executor's TRANSITION_CODEHASH",
    );
    let executor_immutables = [
        ImmutableValue::new(
            "CHAIN_TYPE_MANAGER",
            optional_display(bound_ctm),
            manifest.ctm,
        ),
        ImmutableValue::new(
            "CTM_PROXY_ADMIN",
            optional_display(bound_admin),
            manifest.ctmProxyAdmin,
        ),
        ImmutableValue::new(
            "TRANSITION_CODEHASH",
            optional_display(transition_anchor),
            optional_display(identity.codehash_of("CTMTransition")),
        ),
    ];
    expect_immutable_bearing_identity(
        &provider,
        &identity,
        result,
        "the bound CTM upgrade executor",
        manifest.ctmExecutor,
        "CTMUpgradeExecutor",
        &executor_immutables,
    )
    .await?;

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

    // The coordinator and the core executor it drives: genuine code, the same governance owner
    // as the CTM executor, and (pre-execution) an unbound core executor — stage 2 binds it.
    expect_code_identity(
        &provider,
        &identity,
        result,
        "the coordinator",
        manifest.coordinator,
        "EcosystemUpgradeExecutor",
    )
    .await?;
    let coordinator = EcosystemUpgradeExecutorView::new(manifest.coordinator, &provider);
    let core_executor_addr = tolerate(
        coordinator.CORE_EXECUTOR().call().await,
        result,
        "the coordinator's CORE_EXECUTOR",
    );
    if let Some(core_executor_addr) = core_executor_addr {
        expect_code_identity(
            &provider,
            &identity,
            result,
            "the core executor",
            core_executor_addr,
            "CoreUpgradeExecutor",
        )
        .await?;
        let core_executor = CoreUpgradeExecutorView::new(core_executor_addr, &provider);
        // The two remaining object-type anchors, each held against the reviewed commit's own
        // bytecode for the object type it admits. Neither object has immutables, so the
        // artifact's deployed-bytecode hash IS what a genuine one carries once deployed.
        let core_registry_anchor = tolerate(
            core_executor.CORE_REGISTRY_CODEHASH().call().await,
            result,
            "the core executor's CORE_REGISTRY_CODEHASH",
        );
        expect_anchor_matches_commit(
            &identity,
            result,
            "the core executor's CORE_REGISTRY_CODEHASH",
            core_registry_anchor,
            "CoreRegistry",
        );
        let operation_anchor = tolerate(
            coordinator.OPERATION_CODEHASH().call().await,
            result,
            "the coordinator's OPERATION_CODEHASH",
        );
        expect_anchor_matches_commit(
            &identity,
            result,
            "the coordinator's OPERATION_CODEHASH",
            operation_anchor,
            "EcosystemUpgradeOperation",
        );
        for (label, owner) in [
            (
                "the coordinator",
                tolerate(
                    coordinator.owner().call().await,
                    result,
                    "the coordinator's owner",
                ),
            ),
            (
                "the core executor",
                tolerate(
                    core_executor.owner().call().await,
                    result,
                    "the core executor's owner",
                ),
            ),
        ] {
            match owner {
                Some(owner) if owner == manifest.ctmExecutorOwner => result.report_ok(&format!(
                    "{label} is owned by the same governance as the CTM executor ({owner})"
                )),
                Some(owner) => result.report_error(&format!(
                    "{label} is owned by {owner}, not by the governance the manifest expects ({}): \
                     one lifecycle would answer to two owners",
                    manifest.ctmExecutorOwner
                )),
                None => {}
            }
        }
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
                     (`setCoordinator`, checked below)",
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
    let Some(live_owner) = tolerate(
        executor.owner().call().await,
        result,
        "the executor's owner",
    ) else {
        return Ok(());
    };
    if live_owner == manifest.ctmExecutorOwner {
        result.report_ok(&format!(
            "the executor's owner {live_owner} matches the manifest's expected owner"
        ));
    } else {
        result.report_error(&format!(
            "the executor is owned by {live_owner} but the manifest expects {}: `migrate()` \
             would refuse, and an unnoticed mismatch here is a permanent handover to the wrong \
             owner",
            manifest.ctmExecutorOwner
        ));
    }

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

    let Some(pending_owner) = tolerate(
        executor.pendingOwner().call().await,
        result,
        "the executor's pending owner",
    ) else {
        return Ok(());
    };
    if pending_owner.is_zero() {
        result.report_ok("the executor has no pending owner");
    } else {
        result.report_error(&format!(
            "the executor has a pending owner {pending_owner}: a nomination is outstanding that \
             could take the domain after the edge runs"
        ));
    }

    // ── 4. The departing state the manifest asserts ──
    result.print_info("\n== Departing state ==");
    let ctm = CtmForBootstrapView::new(manifest.ctm, &provider);
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

    // Each CTM-domain row must depart from the implementation that is LIVE, not from whatever
    // the prepare saw: a row at an unexpected implementation reverts stage 1 wholesale.
    let ctm_admin = ProxyAdminView::new(manifest.ctmProxyAdmin, &provider);
    for (i, row) in manifest.proxyUpgrades.iter().enumerate() {
        if row.implNew.is_zero() {
            continue; // an inert row: this edge deliberately does not upgrade that proxy
        }
        let label = format!("CTM-domain row {i} ({})", row.proxy);
        let Some(live_impl) = tolerate(
            ctm_admin.getProxyImplementation(row.proxy).call().await,
            result,
            &format!("{label}: the live implementation of {}", row.proxy),
        ) else {
            continue;
        };
        if live_impl == row.expectedOldImpl {
            result.report_ok(&format!("{label} departs from the live implementation"));
        } else {
            result.report_error(&format!(
                "{label} expects to depart from {} but {live_impl} is live",
                row.expectedOldImpl
            ));
        }
        expect_code_present(&provider, result, &format!("{label} implNew"), row.implNew).await?;
    }

    // ── 5. The ecosystem leg ──
    if let Some(core_registry_addr) = package.core_registry {
        result.print_info("\n== Ecosystem leg ==");
        expect_code_identity(
            &provider,
            &identity,
            result,
            "the core registry",
            core_registry_addr,
            "CoreRegistry",
        )
        .await?;

        let Some(core_executor_addr) = core_executor_addr else {
            result.report_error(
                "the core executor is unknown (the coordinator's CORE_EXECUTOR could not be read), \
                 so the ecosystem leg cannot be checked",
            );
            return Ok(());
        };
        let core_executor = CoreUpgradeExecutorView::new(core_executor_addr, &provider);
        let anchor = tolerate(
            core_executor.CORE_REGISTRY_CODEHASH().call().await,
            result,
            "the core executor's CORE_REGISTRY_CODEHASH",
        );
        let live_code = provider.get_code_at(core_registry_addr).await?;
        let live_hash = alloy::primitives::keccak256(&live_code);
        if anchor == Some(live_hash) {
            result.report_ok("the core executor's CORE_REGISTRY_CODEHASH accepts this registry");
        } else if let Some(anchor) = anchor {
            result.report_error(&format!(
                "the core executor anchors CORE_REGISTRY_CODEHASH {anchor} but the registry at \
                 {core_registry_addr} runs {live_hash}: `applyL1Upgrade` would be rejected"
            ));
        }

        let Some(eco_admin_addr) = tolerate(
            core_executor.PROXY_ADMIN().call().await,
            result,
            "the core executor's PROXY_ADMIN",
        ) else {
            return Ok(());
        };
        let registry = CoreRegistryView::new(core_registry_addr, &provider);
        let eco_admin = ProxyAdminView::new(eco_admin_addr, &provider);
        let Some(rows) = tolerate(
            registry.ecosystemRows().call().await,
            result,
            "the core registry's ecosystemRows()",
        ) else {
            return Ok(());
        };
        for (i, row) in rows.iter().enumerate() {
            if row.implNew.is_zero() {
                continue;
            }
            let label = format!("ecosystem row {i} ({})", row.proxy);
            let Some(live_impl) = tolerate(
                eco_admin.getProxyImplementation(row.proxy).call().await,
                result,
                &format!("{label}: the live implementation of {}", row.proxy),
            ) else {
                continue;
            };
            if live_impl == row.expectedOldImpl {
                result.report_ok(&format!("{label} departs from the live implementation"));
            } else {
                result.report_error(&format!(
                    "{label} expects to depart from {} but {live_impl} is live",
                    row.expectedOldImpl
                ));
            }
            expect_code_present(&provider, result, &format!("{label} implNew"), row.implNew)
                .await?;
        }
    } else {
        result.print_info("\n== Ecosystem leg ==");
        result.report_ok("no core registry: this edge upgrades no shared singletons");
    }

    // ── 6. The timer that gates the edge ──
    result.print_info("\n== Stage sequencing ==");
    let timer: GovernanceUpgradeTimerViewInstance<_> =
        GovernanceUpgradeTimerView::new(manifest.upgradeTimer, &provider);
    let Some(timer_governance) = tolerate(
        timer.TIMER_GOVERNANCE().call().await,
        result,
        "the timer's TIMER_GOVERNANCE()",
    ) else {
        return Ok(());
    };
    // GOVERNANCE starts the bootstrap's timer, not the executor: at stage 0 the executor does
    // not hold the CTM domain yet (`CTMUpgrade_v34.timerGovernance`). Only every LATER upgrade
    // binds its timer to the executor, which `CTMUpgradeExecutor.stage0` then enforces.
    //
    // `TIMER_GOVERNANCE` is also a constructor-set immutable, so the timer's runtime code cannot
    // hash to its artifact — which is why this value IS the timer's identity check.
    expect_immutable_bearing_identity(
        &provider,
        &identity,
        result,
        "the upgrade timer",
        manifest.upgradeTimer,
        "GovernanceUpgradeTimer",
        &[ImmutableValue::new(
            "TIMER_GOVERNANCE",
            timer_governance,
            manifest.ctmExecutorOwner,
        )],
    )
    .await?;
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

    if package.release != manifest.currentRelease {
        result.report_warn(&format!(
            "the package reports ctm_release_addr {} but the manifest names {}: the prepare's \
             summary disagrees with the object governance will execute",
            package.release, manifest.currentRelease
        ));
    }
    match package.upgrade_timer {
        Some(reported) if reported != manifest.upgradeTimer => result.report_warn(&format!(
            "the package reports upgrade_timer_addr {reported} but the manifest names {}",
            manifest.upgradeTimer
        )),
        Some(_) => result.report_ok("the package's reported timer matches the manifest"),
        None => result.report_warn(
            "the package does not report upgrade_timer_addr, so the timer is taken from the \
             manifest alone — a package produced before the prepare output named it",
        ),
    }

    // ── 7. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    verify_stage0_shape(&package, result);
    verify_stage1_shape(&package, &manifest, core_executor_addr, result);
    verify_stage2_shape(&package, &manifest, core_executor_addr, &provider, result).await;

    // A bootstrap edge legitimately declares external actions — the handovers and the pause
    // window are exactly the calls no object can describe yet, which is why the prepare
    // declares them. They are the reviewable list, so they are PRINTED rather than flagged;
    // flagging each one buried the real findings under expected output.
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

/// Stage 0 opens the operational window: migrations must be paused before the CTM's own
/// version commit will run, so a package whose stage 0 does not pause cannot reach stage 1.
fn verify_stage0_shape(package: &BootstrapPackage, result: &mut VerificationResult) {
    let pauses = package
        .stage0
        .iter()
        .any(|c| c.data.get(..4) == Some(&PAUSE_MIGRATION_SELECTOR[..]));
    if pauses {
        result.report_ok("stage 0 pauses chain migrations");
    } else {
        result.report_error(
            "stage 0 never pauses chain migrations: the CTM's version commit refuses to run \
             unpaused, so stage 1 could not complete",
        );
    }
}

/// Stage 2 closes it, asserts the edge actually applied and binds the core executor to the
/// coordinator. The completion gate is the last call of a derived stage 2, so its absence is not
/// a forgotten convention but a bundle that does not match the object it claims to come from.
/// Without `setCoordinator` no later operation could reserve the ecosystem leg.
async fn verify_stage2_shape<P: Provider>(
    package: &BootstrapPackage,
    manifest: &views::BootstrapManifest,
    core_executor: Option<Address>,
    provider: &P,
    result: &mut VerificationResult,
) {
    let binds_core_executor = package.stage2.iter().any(|c| {
        Some(c.target) == core_executor
            && c.data.get(..4) == Some(&SET_COORDINATOR_SELECTOR[..])
            && c.data.get(4..36).map(|w| Address::from_slice(&w[12..]))
                == Some(manifest.coordinator)
    });
    if binds_core_executor {
        result.report_ok("stage 2 binds the core executor to the coordinator (`setCoordinator`)");
    } else {
        result.report_error(
            "stage 2 never binds the core executor to the coordinator: no later operation could \
             reserve the ecosystem leg",
        );
    }

    let expected_binding = EcosystemUpgradeExecutorView::setCTMExecutorCall {
        _ctmExecutor: manifest.ctmExecutor,
    }
    .abi_encode();
    if package.stage2.iter().any(|call| {
        call.target == manifest.coordinator && call.value.is_zero() && call.data == expected_binding
    }) {
        result.report_ok("stage 2 binds the coordinator to the reviewed CTM executor");
    } else {
        result.report_error("stage 2 never binds the coordinator to the reviewed CTM executor");
    }

    verify_completion_gate(package, provider, result).await;

    let unpauses = package
        .stage2
        .iter()
        .any(|c| c.data.get(..4) == Some(&UNPAUSE_MIGRATION_SELECTOR[..]));
    if unpauses {
        result.report_ok("stage 2 unpauses chain migrations");
    } else {
        result.report_warn(
            "stage 2 never unpauses chain migrations: the ecosystem would stay paused after the \
             edge completes",
        );
    }
}

/// The terminal call of stage 2 is the edge's completion gate: `validateApplied()` on the
/// `RegistryBootstrapSequence` the prepare derived the whole bundle from, which asserts BOTH
/// domains — the migration's own post-state check and the core executor's applied-row check —
/// in one call that cannot be half-dropped.
///
/// The sequence is recovered from that call rather than read from a field, for the same reason
/// the migration is recovered from `migrate()`: the verifier checks the calldata governance will
/// execute. Its two objects are then read live and held against the rest of the package, so a
/// terminal call pointing at some other contract that merely answers `validateApplied()` is a
/// finding rather than a pass.
async fn verify_completion_gate<P: Provider>(
    package: &BootstrapPackage,
    provider: &P,
    result: &mut VerificationResult,
) {
    let Some(last) = package.stage2.last() else {
        result.report_error(
            "stage 2 is empty: a derived bootstrap sequence always ends with the completion gate",
        );
        return;
    };
    if last.data != VALIDATE_APPLIED_SELECTOR || !last.value.is_zero() {
        result.report_error(
            "stage 2 does not end with the edge's completion gate (`validateApplied()`): \
             governance would complete without the edge proving it reached the intended state, \
             and the bundle is not the one the derived sequence describes",
        );
        return;
    }

    let sequence = views::RegistryBootstrapSequenceView::new(last.target, provider);
    let named_migration = match sequence.MIGRATION().call().await {
        Ok(addr) => addr,
        Err(e) => {
            result.report_error(&format!(
                "the completion gate at {} does not answer `MIGRATION()` ({e}): it is not the \
                 bootstrap sequence this package's calls were derived from",
                last.target
            ));
            return;
        }
    };
    if named_migration != package.migration {
        result.report_error(&format!(
            "the completion gate at {} describes the edge at {named_migration}, but stage 1 \
             calls `migrate()` on {}: the gate would assert a different edge applied",
            last.target, package.migration
        ));
        return;
    }

    let named_registry = match sequence.CORE_REGISTRY().call().await {
        Ok(addr) => addr,
        Err(e) => {
            result.report_error(&format!(
                "the completion gate at {} does not answer `CORE_REGISTRY()` ({e})",
                last.target
            ));
            return;
        }
    };
    match package.core_registry {
        Some(reported) if reported != named_registry => result.report_error(&format!(
            "the completion gate asserts the ecosystem inventory {named_registry}, but the \
             package's core leg applies {reported}: the gate would pass over an unapplied \
             ecosystem",
        )),
        _ => result.report_ok(
            "stage 2 ends with the derived completion gate, asserting both domains applied \
             (`validateApplied()` over the reviewed migration and core registry)",
        ),
    }
}

/// Stage 1 of a bootstrap edge is a fixed, small shape: hand the CTM to the migration, hand its
/// ProxyAdmin to the migration, then `migrate()`. Anything else in that stage is a call a
/// reviewer has to justify, so it is reported rather than assumed benign.
fn verify_stage1_shape(
    package: &BootstrapPackage,
    manifest: &views::BootstrapManifest,
    core_executor: Option<Address>,
    result: &mut VerificationResult,
) {
    let migration = package.migration;
    let mut saw_ctm_handover = false;
    let mut saw_admin_handover = false;
    let mut saw_ecosystem_admin_handover = false;
    let mut saw_apply_l1 = false;
    let mut saw_pause_reassert = false;
    let mut unexpected: Vec<String> = Vec::new();

    for call in &package.stage1 {
        let selector = call.data.get(..4).unwrap_or_default();
        if selector == TRANSFER_OWNERSHIP_SELECTOR {
            // The argument is the sole 32-byte word after the selector.
            let handed_to = call
                .data
                .get(4..36)
                .map(|w| Address::from_slice(&w[12..]))
                .unwrap_or_default();
            if Some(handed_to) == core_executor {
                // The ecosystem leg: the shared ProxyAdmin goes to the core executor, not to
                // the migration. Expected in any edge that carries a CoreRegistry.
                saw_ecosystem_admin_handover = true;
            } else if handed_to != migration {
                unexpected.push(format!(
                    "transferOwnership on {} hands to {handed_to}, which is neither the \
                     migration nor the core executor",
                    call.target
                ));
            } else if call.target == manifest.ctm {
                saw_ctm_handover = true;
            } else if call.target == manifest.ctmProxyAdmin {
                saw_admin_handover = true;
            } else {
                unexpected.push(format!(
                    "transferOwnership hands {} to the migration, which is neither the CTM nor \
                     its ProxyAdmin",
                    call.target
                ));
            }
        } else if selector == MIGRATE_SELECTOR {
            if call.target != migration {
                unexpected.push(format!("migrate() on an unexpected target {}", call.target));
            }
        } else if selector == APPLY_L1_UPGRADE_SELECTOR {
            if Some(call.target) == core_executor {
                saw_apply_l1 = true;
            } else {
                unexpected.push(format!(
                    "applyL1Upgrade on {}, which is not the coordinator's core executor",
                    call.target
                ));
            }
        } else if selector == PAUSE_MIGRATION_SELECTOR {
            // Re-asserted in stage 1 because the EUB path's built-in pre-step unpauses.
            saw_pause_reassert = true;
        } else {
            unexpected.push(format!(
                "unrecognised stage-1 call to {} (selector 0x{})",
                call.target,
                alloy::hex::encode(selector)
            ));
        }
    }

    if saw_ctm_handover {
        result.report_ok("stage 1 nominates the migration as the CTM's owner");
    } else {
        result
            .report_error("stage 1 never hands the CTM to the migration: `migrate()` would refuse");
    }
    if saw_admin_handover {
        result.report_ok("stage 1 hands the CTM ProxyAdmin to the migration");
    } else {
        result.report_error(
            "stage 1 never hands the CTM ProxyAdmin to the migration: `migrate()` would refuse",
        );
    }
    if saw_pause_reassert {
        result.report_ok("stage 1 re-asserts the migration pause");
    }
    match (saw_ecosystem_admin_handover, saw_apply_l1) {
        (true, true) => result.report_ok(
            "stage 1 carries the ecosystem leg: the shared ProxyAdmin goes to the core executor, \
             which then applies the pinned inventory",
        ),
        (false, false) => result.report_ok("stage 1 carries no ecosystem leg"),
        (admin, apply) => result.report_error(&format!(
            "stage 1's ecosystem leg is incomplete: ProxyAdmin handover {}, applyL1Upgrade {} \
             — the executor cannot apply an inventory over an admin it does not own",
            if admin { "present" } else { "MISSING" },
            if apply { "present" } else { "MISSING" }
        )),
    }
    for line in unexpected {
        result.report_warn(&format!("stage 1: {line}"));
    }
}

/// Holds one object-type ANCHOR against the reviewed commit's bytecode for the object type it
/// admits.
///
/// The anchor is an executor immutable: an expectation established when the executor was
/// deployed, which every later, arbitrary input is held against. So the question is whether it
/// admits the REVIEWED object type — never whether it agrees with a value this package carries.
fn expect_anchor_matches_commit(
    identity: &CodeIdentity,
    result: &mut VerificationResult,
    label: &str,
    anchor: Option<alloy::primitives::FixedBytes<32>>,
    expected_short_name: &str,
) {
    let Some(anchor) = anchor else {
        return;
    };
    match identity.codehash_of(expected_short_name) {
        Some(reviewed) if reviewed == anchor => {
            result.report_ok(&format!(
                "{label} admits the reviewed {expected_short_name}"
            ));
        }
        Some(reviewed) => result.report_error(&format!(
            "{label} is {anchor}, but the reviewed commit builds {expected_short_name} to \
             {reviewed}: an object built from the reviewed sources would be rejected"
        )),
        None => result.report_error(&format!(
            "{label} cannot be checked: AllContractsHashes.json has no \
             {expected_short_name} entry for the reviewed commit"
        )),
    }
}

/// Renders an optional read for an [`ImmutableValue`], so a getter that reverted compares
/// unequal instead of silently dropping the check.
fn optional_display<T: std::fmt::Display>(value: Option<T>) -> String {
    value.map_or_else(|| "<unreadable>".to_string(), |v| v.to_string())
}

/// Renders a packed SemVer protocol version the way the upgrade envs and release notes write it.
fn format_semver(packed: U256) -> String {
    // A version wider than the packed encoding is malformed rather than unrepresentable, so it
    // is reported verbatim: panicking would take the whole report down over one bad field.
    let Ok(raw) = TryInto::<u128>::try_into(packed) else {
        return format!("<malformed version {packed}>");
    };
    let major = raw >> 64;
    let minor = (raw >> 32) & 0xffff_ffff;
    let patch = raw & 0xffff_ffff;
    format!("v{major}.{minor}.{patch}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_a_packed_semver() {
        // 0x2200000001 is v0.34.1 in the packed encoding the CTM stores.
        assert_eq!(format_semver(U256::from(0x22_0000_0001u64)), "v0.34.1");
        assert_eq!(format_semver(U256::from(0x22_0000_0000u64)), "v0.34.0");
        assert_eq!(format_semver(U256::from(0x21_0000_0000u64)), "v0.33.0");
    }
}
