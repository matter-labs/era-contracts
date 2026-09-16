//! Verification of a v34 registry-driven upgrade package.
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
//!   2. Was every object PRODUCED by that code's constructor from the manifest it serves?
//!      (`construction`) — the question a runtime codehash cannot answer, and the reason the
//!      chain no longer pretends to answer it.
//!   3. Does every contract the manifest names exist?
//!   4. Is authority bound as the manifest claims, and to the expected governance owner?
//!   5. Does every proxy row depart from the implementation that is actually live?
//!   6. Does the transaction governance signs invoke the reviewed upgrade, at the reviewed
//!      address?
//!
//! None of it is "does the manifest's own fingerprint of a member match that member's code": the
//! manifest author supplies both halves of such a pair, so it can only ever agree with itself.
//! Every comparison here is against the reviewed commit or against live state the package does
//! not control.
//!
//! # Two kinds of package
//!
//! The ordinary case is a RECURRING upgrade, verified by [`operation`]: one
//! `EcosystemUpgradeOperation`, and three governance calls that are a pure function of its
//! address. This module handles the other kind — the one-time BOOTSTRAP edge that installs the
//! registry model on a CTM that predates it. A bootstrap has no operation and no coordinator, so
//! governance executes a list of ordinary calls instead; see [`verify_derived_sequence`] for why
//! that list has to be compared at all, and why nothing else should be built on that comparison.
//!
//! # What it deliberately does not do
//!
//! It does not re-derive facet cuts, L2 transactions or proposals. Those are derived on-chain
//! from the release pair, and `TransitionDerivationLib` is audited code — re-deriving them here
//! would be a second implementation to keep in sync, which is exactly what the registry model
//! set out to remove. It also does not call the objects' own `validate()`: that runs against
//! post-handover state (it requires the migration to already hold both ownerships), so
//! pre-execution it reverts by design and tells a reviewer nothing.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolValue;

use crate::common::ethereum::get_provider;
use crate::upgrade_verification::report::VerificationResult;

pub(crate) mod construction;
pub(crate) mod operation;
pub(crate) mod package;
pub(crate) mod provenance;
pub(crate) mod views;

use construction::{expect_canonical_construction, ReviewedBuild};
use package::{
    BootstrapPackage, RegistryPackage, TRANSFER_OWNERSHIP_SELECTOR, VALIDATE_APPLIED_SELECTOR,
};
use provenance::{
    expect_code_identity, expect_code_present, expect_immutable_bearing_identity, tolerate,
    CodeIdentity, ImmutableValue,
};
use views::{
    BridgehubView, CTMReleaseView, CTMUpgradeExecutorView, CommittedUpgradeView, CoreRegistryView,
    CoreUpgradeExecutorView, CtmView, EcosystemUpgradeExecutorView, GovernanceUpgradeTimerView,
    GovernanceUpgradeTimerView::GovernanceUpgradeTimerViewInstance, ProxyAdminView,
    RegistryBootstrapMigrationView,
};

/// Verify a v34 registry-driven upgrade package against the live L1 it targets.
///
/// The package's own content decides which verifier runs — a recurring operation or a bootstrap
/// edge (see [`RegistryPackage::load`]); a package that is neither is refused rather than
/// verified as the nearest match.
///
/// `expected_governance_owner` is the reviewed address the upgrade must be driven by. For a
/// bootstrap that is the owner the CTM domain lands on permanently; for a recurring upgrade it is
/// the owner of the whole lifecycle.
pub(crate) async fn verify(
    ecosystem_toml: &std::path::Path,
    l1_rpc_url: &str,
    expected_governance_owner: Option<Address>,
    extra_create2_salts: &[B256],
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let provider = get_provider(l1_rpc_url)?;
    let identity = CodeIdentity::from_local_hashes()?;
    let build = ReviewedBuild::load(&identity);

    match RegistryPackage::load(ecosystem_toml)? {
        RegistryPackage::Operation(package) => {
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            operation::verify(
                &provider,
                &identity,
                &build,
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
        RegistryPackage::Bootstrap(package) => {
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            verify_bootstrap(
                &provider,
                &identity,
                &build,
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
    }
}

/// Verify the one-time bootstrap edge onto the registry model.
#[allow(clippy::too_many_arguments)]
async fn verify_bootstrap<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    package: &BootstrapPackage,
    expected_governance_owner: Option<Address>,
    salts: &[B256],
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    // The set of addresses this run establishes as reviewed. Every governance call must land on
    // one of them (or on a live contract the manifest itself names), which is the last of the
    // three things a reviewer has to be able to say: the calls execute the objects that were
    // reviewed, not ones that merely look like them.
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
    if let Some(core_registry_addr) = package.core_registry {
        verify_core_registry_construction(
            provider,
            build,
            result,
            core_registry_addr,
            salts,
            &mut reviewed,
        )
        .await;
    }
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

    // ── 3. Authority: the binding, and the owner it lands on ──
    result.print_info("\n== Bound authority ==");
    let executor = CTMUpgradeExecutorView::new(manifest.ctmExecutor, provider);
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
    ];
    expect_immutable_bearing_identity(
        provider,
        identity,
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
        provider,
        identity,
        result,
        "the coordinator",
        manifest.coordinator,
        "EcosystemUpgradeExecutor",
    )
    .await?;
    let coordinator = EcosystemUpgradeExecutorView::new(manifest.coordinator, provider);
    let core_executor_addr = tolerate(
        coordinator.CORE_EXECUTOR().call().await,
        result,
        "the coordinator's CORE_EXECUTOR",
    );
    if let Some(core_executor_addr) = core_executor_addr {
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

    // Each CTM-domain row must depart from the implementation that is LIVE, not from whatever
    // the prepare saw: a row at an unexpected implementation reverts stage 1 wholesale.
    let ctm_admin = ProxyAdminView::new(manifest.ctmProxyAdmin, provider);
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
        expect_code_present(provider, result, &format!("{label} implNew"), row.implNew).await?;
    }

    // ── 5. The ecosystem leg ──
    if let Some(core_registry_addr) = package.core_registry {
        result.print_info("\n== Ecosystem leg ==");
        expect_code_identity(
            provider,
            identity,
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
        let core_executor = CoreUpgradeExecutorView::new(core_executor_addr, provider);
        let Some(eco_admin_addr) = tolerate(
            core_executor.PROXY_ADMIN().call().await,
            result,
            "the core executor's PROXY_ADMIN",
        ) else {
            return Ok(());
        };
        let registry = CoreRegistryView::new(core_registry_addr, provider);
        let eco_admin = ProxyAdminView::new(eco_admin_addr, provider);
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
            expect_code_present(provider, result, &format!("{label} implNew"), row.implNew).await?;
        }
    } else {
        result.print_info("\n== Ecosystem leg ==");
        result.report_ok("no core registry: this edge upgrades no shared singletons");
    }

    // ── 6. The timer that gates the edge ──
    result.print_info("\n== Stage sequencing ==");
    let timer: GovernanceUpgradeTimerViewInstance<_> =
        GovernanceUpgradeTimerView::new(manifest.upgradeTimer, provider);
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
        provider,
        identity,
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
        // An ERROR, not a note: `ctm_release_addr` is what a human reads out of the package, and
        // the manifest is what executes. A disagreement means the reviewer reviewed a different
        // object from the one governance would install.
        result.report_error(&format!(
            "the package reports ctm_release_addr {} but the manifest names {}: the summary a \
             reviewer reads describes a different release from the one governance would install",
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
    verify_derived_sequence(package, provider, result).await;

    // The pause/unpause calls land on the CTM's own ChainAssetHandler, which no manifest names;
    // it is derived from the CTM's Bridgehub so a call to it is accounted for as that contract
    // rather than as an unexplained address.
    // An unreadable hop is not silently tolerated: it just leaves the handler unaccounted, and
    // `verify_call_targets` then reports the pause call's target as an address this review does
    // not explain — which is the honest outcome.
    let chain_asset_handler = match ctm.BRIDGE_HUB().call().await {
        Ok(bridgehub) => BridgehubView::new(bridgehub, provider)
            .chainAssetHandler()
            .call()
            .await
            .ok(),
        Err(_) => None,
    };
    verify_call_targets(
        package,
        &manifest,
        core_executor_addr,
        chain_asset_handler,
        &reviewed,
        result,
    );

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

/// The reviewed salts: whatever the package recorded, plus whatever the reviewer supplied,
/// de-duplicated and order-stable so the report names the same salt run after run.
fn merge_salts(from_package: &[B256], from_reviewer: &[B256]) -> Vec<B256> {
    let mut salts: Vec<B256> = Vec::new();
    for salt in from_package.iter().chain(from_reviewer) {
        if !salts.contains(salt) {
            salts.push(*salt);
        }
    }
    salts
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

/// The core registry's construction, re-derived from the manifest it serves.
async fn verify_core_registry_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    core_registry: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) {
    let view = CoreRegistryView::new(core_registry, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the core registry at {core_registry} does not answer `getManifest()` ({e}): its \
                 construction cannot be verified"
            ));
            return;
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
}

/// Prints the DERIVED payload an object constructed at its own construction.
///
/// This is the state a counterfeit exists to tamper with — the L2 force deployments and the
/// delegate leg every chain executes — so it is rendered for the reviewer rather than only
/// summarised. Its agreement with the manifest is what the construction check above establishes;
/// what a human still has to read is whether the payload IS the proposal.
async fn render_derived_payloads<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    object: Address,
) {
    let view = CommittedUpgradeView::new(object, provider);
    let Ok(plan) = view.l2Plan().call().await else {
        result.report_error(&format!(
            "the object at {object} does not answer `l2Plan()`: its derived payload cannot be \
             shown, so a reviewer cannot check it against the proposal"
        ));
        return;
    };
    result.print_info(&format!(
        "  derived L2 plan: {} force deployment(s), delegateTo {}, composer {}, {} factory \
         dependency hash(es)",
        plan.deployments.len(),
        plan.delegateTo,
        plan.delegateComposer,
        plan.factoryDepHashes.len()
    ));
    for (i, deployment) in plan.deployments.iter().enumerate() {
        result.print_info(&format!(
            "    deployment {i}: type {} at {} ({} bytes of bytecode info)",
            deployment.upgradeType,
            deployment.newAddress,
            deployment.deployedBytecodeInfo.len()
        ));
    }
}

/// Answers the last question a reviewer must be able to answer: do the calls governance signs
/// land on the objects this run established, and nowhere else?
///
/// Every target is either a reviewed object or a live contract the MANIFEST names (the CTM, its
/// ProxyAdmin, the executors, the timer, the chain asset handler) — the manifest being itself
/// covered by the construction check. Anything else is an ERROR: a call to an address no part of
/// the review accounts for is precisely how a package would slip an unreviewed object past.
fn verify_call_targets(
    package: &BootstrapPackage,
    manifest: &views::BootstrapManifest,
    core_executor: Option<Address>,
    chain_asset_handler: Option<Address>,
    reviewed: &BTreeMap<Address, String>,
    result: &mut VerificationResult,
) {
    let mut accounted: BTreeMap<Address, String> = reviewed.clone();
    fn note(accounted: &mut BTreeMap<Address, String>, addr: Address, what: &str) {
        if !addr.is_zero() {
            accounted.entry(addr).or_insert_with(|| what.to_string());
        }
    }
    note(&mut accounted, manifest.ctm, "the CTM the manifest names");
    note(
        &mut accounted,
        manifest.ctmProxyAdmin,
        "the CTM-domain ProxyAdmin the manifest names",
    );
    note(
        &mut accounted,
        manifest.ctmExecutor,
        "the CTM executor the manifest names",
    );
    note(
        &mut accounted,
        manifest.coordinator,
        "the coordinator the manifest names",
    );
    note(
        &mut accounted,
        manifest.upgradeTimer,
        "the timer the manifest names",
    );
    if let Some(core_executor) = core_executor {
        note(
            &mut accounted,
            core_executor,
            "the core executor the coordinator names",
        );
    }
    if let Some(handler) = chain_asset_handler {
        note(
            &mut accounted,
            handler,
            "the ChainAssetHandler the CTM's Bridgehub names",
        );
    }
    // Stage 2 ends on the derived bootstrap sequence, which no manifest names; it is held
    // against the package by `verify_completion_gate` instead, so it is accounted for here by
    // that role rather than left looking unreviewed.
    if let Some(last) = package.stage2.last() {
        note(
            &mut accounted,
            last.target,
            "the bootstrap sequence terminating stage 2",
        );
    }
    // The ecosystem ProxyAdmin is handed to the core executor in stage 1 and is in no manifest;
    // it is identified by that handover and checked there.
    for call in &package.stage1 {
        if call.data.get(..4) == Some(&TRANSFER_OWNERSHIP_SELECTOR[..])
            && call.data.get(4..36).map(|w| Address::from_slice(&w[12..])) == core_executor
        {
            note(
                &mut accounted,
                call.target,
                "the ecosystem ProxyAdmin handed to the core executor",
            );
        }
    }

    let mut unaccounted = 0usize;
    for (stage, calls) in [
        ("stage 0", &package.stage0),
        ("stage 1", &package.stage1),
        ("stage 2", &package.stage2),
    ] {
        for call in calls {
            match accounted.get(&call.target) {
                Some(what) => {
                    result.print_info(&format!("  {stage} -> {what} ({})", call.target));
                }
                None => {
                    unaccounted += 1;
                    result.report_error(&format!(
                        "{stage} calls {} (selector 0x{}), an address no part of this review \
                         accounts for: the bundle would execute something that was not reviewed",
                        call.target,
                        alloy::hex::encode(call.data.get(..4).unwrap_or_default())
                    ));
                }
            }
        }
    }
    if unaccounted == 0 {
        result.report_ok(
            "every governance call targets an object or contract this review established",
        );
    }
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
/// The sequence is recovered from the terminal `validateApplied()` call rather than read from a
/// field, for the same reason the migration is recovered from `migrate()`: the verifier checks
/// the calldata governance will execute. Its two objects are then held against the rest of the
/// package, so a terminal call pointing at some other contract that merely answers
/// `validateApplied()` is a finding rather than a pass.
async fn verify_derived_sequence<P: Provider>(
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
    match sequence.CORE_REGISTRY().call().await {
        Ok(named_registry) => match package.core_registry {
            Some(reported) if reported != named_registry => {
                result.report_error(&format!(
                    "the completion gate asserts the ecosystem inventory {named_registry}, but \
                     the package's core leg applies {reported}: the gate would pass over an \
                     unapplied ecosystem"
                ));
                return;
            }
            _ => result.report_ok(&format!(
                "stage 2 ends with the completion gate of the sequence at {} (`validateApplied()` \
                 over the reviewed migration and core registry)",
                last.target
            )),
        },
        Err(e) => {
            result.report_error(&format!(
                "the completion gate at {} does not answer `CORE_REGISTRY()` ({e})",
                last.target
            ));
            return;
        }
    }

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
                    "the sequence at {} does not answer `stage{stage}Actions()` ({e}): the \
                     submitted stage-{stage} calls cannot be held against the list it derives",
                    last.target
                ));
                continue;
            }
        };

        // In ORDER and one-for-one: the derived calls are a contiguous run inside the stage, and
        // whatever else the merge appended sits around them. An out-of-order run is a finding —
        // the edge's own steps depend on each other (the pause before the version commit, the
        // handovers before `migrate()`).
        let position = submitted
            .windows(derived.len().max(1))
            .position(|window| {
                derived.len() == window.len()
                    && derived.iter().zip(window).all(|(action, call)| {
                        action.call.target == call.target
                            && action.call.value == call.value
                            && action.call.data[..] == call.data[..]
                    })
            })
            .filter(|_| !derived.is_empty());
        match position {
            Some(at) => {
                result.report_ok(&format!(
                    "stage {stage} carries the {} call(s) the sequence derives, in order (at \
                     offset {at} of {} submitted)",
                    derived.len(),
                    submitted.len()
                ));
                for action in derived.iter() {
                    result.print_info(&format!(
                        "    · {} — {} (authority: {})",
                        action.label, action.call.target, action.authority
                    ));
                }
            }
            None => result.report_error(&format!(
                "stage {stage}'s {} submitted call(s) do not contain the {} call(s) the sequence \
                 at {} derives, in order: governance would sign a bundle the reviewed edge does \
                 not describe",
                submitted.len(),
                derived.len(),
                last.target
            )),
        }
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

    #[test]
    fn salts_from_the_package_and_the_reviewer_merge_without_duplicates() {
        let a = B256::repeat_byte(0xAA);
        let b = B256::repeat_byte(0xBB);
        assert_eq!(merge_salts(&[a, b], &[b, a]), vec![a, b]);
        assert_eq!(merge_salts(&[], &[a]), vec![a]);
        assert!(merge_salts(&[], &[]).is_empty());
    }

    #[test]
    fn formats_a_packed_semver() {
        // 0x2200000001 is v0.34.1 in the packed encoding the CTM stores.
        assert_eq!(format_semver(U256::from(0x22_0000_0001u64)), "v0.34.1");
        assert_eq!(format_semver(U256::from(0x22_0000_0000u64)), "v0.34.0");
        assert_eq!(format_semver(U256::from(0x21_0000_0000u64)), "v0.33.0");
    }
}
