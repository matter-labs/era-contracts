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
//!   2. Do the manifest's inline pins hold against live code?
//!   3. Is authority bound as the manifest claims, and to the expected governance owner?
//!   4. Does every proxy row depart from the implementation that is actually live?
//!   5. Is the edge un-executed, and does the calldata contain only the expected calls?
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

use crate::common::ethereum::get_provider;
use crate::upgrade_verification::verifiers::VerificationResult;

pub(crate) mod package;
pub(crate) mod provenance;
pub(crate) mod views;

use package::{
    BootstrapPackage, APPLY_L1_UPGRADE_SELECTOR, MIGRATE_SELECTOR, PAUSE_MIGRATION_SELECTOR,
    TRANSFER_OWNERSHIP_SELECTOR, UNPAUSE_MIGRATION_SELECTOR, VALIDATE_APPLIED_SELECTOR,
};
use provenance::{expect_code_identity, expect_pin_holds, tolerate, CodeIdentity};
use views::{
    CTMUpgradeExecutorView, CoreRegistryView, CtmForBootstrapView, EcosystemUpgradeExecutorView,
    GovernanceUpgradeTimerView, GovernanceUpgradeTimerView::GovernanceUpgradeTimerViewInstance,
    ProxyAdminView, RegistryBootstrapMigrationView,
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

    // ── 1. The migration itself, and its pinned manifest ──
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
        "the pinned release",
        manifest.currentRelease.addr,
        "CTMRelease",
    )
    .await?;
    expect_code_identity(
        &provider,
        &identity,
        result,
        "the bound CTM upgrade executor",
        manifest.ctmExecutor.addr,
        "CTMUpgradeExecutor",
    )
    .await?;
    expect_code_identity(
        &provider,
        &identity,
        result,
        "the pinned upgrade timer",
        manifest.upgradeTimer.addr,
        "GovernanceUpgradeTimer",
    )
    .await?;

    // ── 2. Every inline pin holds against live code ──
    result.print_info("\n== Manifest pins ==");
    expect_pin_holds(
        &provider,
        result,
        "manifest.currentRelease",
        manifest.currentRelease.addr,
        manifest.currentRelease.codehash,
    )
    .await?;
    expect_pin_holds(
        &provider,
        result,
        "manifest.upgradeEngine",
        manifest.upgradeEngine.addr,
        manifest.upgradeEngine.codehash,
    )
    .await?;
    expect_pin_holds(
        &provider,
        result,
        "manifest.ctmExecutor",
        manifest.ctmExecutor.addr,
        manifest.ctmExecutor.codehash,
    )
    .await?;
    expect_pin_holds(
        &provider,
        result,
        "manifest.upgradeTimer",
        manifest.upgradeTimer.addr,
        manifest.upgradeTimer.codehash,
    )
    .await?;

    // ── 3. Authority: the binding, and the owner it lands on ──
    result.print_info("\n== Bound authority ==");
    let executor = CTMUpgradeExecutorView::new(manifest.ctmExecutor.addr, &provider);

    let Some(bound_ctm) = tolerate(
        executor.CHAIN_TYPE_MANAGER().call().await,
        result,
        "the executor's bound CTM",
    ) else {
        return Ok(());
    };
    if bound_ctm == manifest.ctm {
        result.report_ok(&format!(
            "the executor is bound to the manifest's CTM {bound_ctm}"
        ));
    } else {
        result.report_error(&format!(
            "the executor is bound to CTM {bound_ctm} but the manifest names {}: the edge would \
             hand authority over a different CTM",
            manifest.ctm
        ));
    }

    let Some(bound_admin) = tolerate(
        executor.CTM_PROXY_ADMIN().call().await,
        result,
        "the executor's bound ProxyAdmin",
    ) else {
        return Ok(());
    };
    if bound_admin == manifest.ctmProxyAdmin {
        result.report_ok(&format!(
            "the executor is bound to CTM ProxyAdmin {bound_admin}"
        ));
    } else {
        result.report_error(&format!(
            "the executor is bound to ProxyAdmin {bound_admin} but the manifest hands over {}",
            manifest.ctmProxyAdmin
        ));
    }

    let Some(ecosystem_executor) = tolerate(
        executor.ECOSYSTEM_EXECUTOR().call().await,
        result,
        "the executor's ecosystem executor",
    ) else {
        return Ok(());
    };
    if ecosystem_executor == manifest.ecosystemExecutor {
        result.report_ok("the executor's ecosystem executor matches the manifest");
    } else {
        result.report_error(&format!(
            "the executor names ecosystem executor {ecosystem_executor} but the manifest names {}",
            manifest.ecosystemExecutor
        ));
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
        if row.implNew.addr.is_zero() {
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
        expect_pin_holds(
            &provider,
            result,
            &format!("{label} implNew"),
            row.implNew.addr,
            row.implNew.codehash,
        )
        .await?;
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

        let eco_executor = EcosystemUpgradeExecutorView::new(manifest.ecosystemExecutor, &provider);
        let pinned = tolerate(
            eco_executor.CORE_REGISTRY_CODEHASH().call().await,
            result,
            "the ecosystem executor's CORE_REGISTRY_CODEHASH",
        );
        let live_code = provider.get_code_at(core_registry_addr).await?;
        let live_hash = alloy::primitives::keccak256(&live_code);
        if pinned == Some(live_hash) {
            result
                .report_ok("the ecosystem executor's CORE_REGISTRY_CODEHASH accepts this registry");
        } else if let Some(pinned) = pinned {
            result.report_error(&format!(
                "the ecosystem executor pins CORE_REGISTRY_CODEHASH {pinned} but the registry at \
                 {core_registry_addr} runs {live_hash}: `applyL1Upgrade` would be rejected"
            ));
        }

        let Some(eco_admin_addr) = tolerate(
            eco_executor.PROXY_ADMIN().call().await,
            result,
            "the ecosystem executor's PROXY_ADMIN",
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
            if row.implNew.addr.is_zero() {
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
            expect_pin_holds(
                &provider,
                result,
                &format!("{label} implNew"),
                row.implNew.addr,
                row.implNew.codehash,
            )
            .await?;
        }
    } else {
        result.print_info("\n== Ecosystem leg ==");
        result.report_ok("no core registry: this edge upgrades no shared singletons");
    }

    // ── 6. The timer that gates the edge ──
    result.print_info("\n== Stage sequencing ==");
    let timer: GovernanceUpgradeTimerViewInstance<_> =
        GovernanceUpgradeTimerView::new(manifest.upgradeTimer.addr, &provider);
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
    if timer_governance == manifest.ctmExecutorOwner {
        result.report_ok(
            "the pinned timer is governed by the same address that owns the executor, so \
             governance can start it at stage 0",
        );
    } else if timer_governance == manifest.ctmExecutor.addr {
        result.report_error(
            "the pinned timer is governed by the bound executor: correct for a recurring \
             upgrade, but at bootstrap stage 0 the executor does not hold the domain yet, so \
             nobody can start this timer",
        );
    } else {
        result.report_error(&format!(
            "the pinned timer is governed by {timer_governance}, which neither owns the executor \
             ({}) nor is the executor itself: stage 0 could not start it",
            manifest.ctmExecutorOwner
        ));
    }

    if package.release != manifest.currentRelease.addr {
        result.report_warn(&format!(
            "the package reports ctm_release_addr {} but the manifest pins {}: the prepare's \
             summary disagrees with the object governance will execute",
            package.release, manifest.currentRelease.addr
        ));
    }
    match package.upgrade_timer {
        Some(reported) if reported != manifest.upgradeTimer.addr => result.report_warn(&format!(
            "the package reports upgrade_timer_addr {reported} but the manifest pins {}",
            manifest.upgradeTimer.addr
        )),
        Some(_) => result.report_ok("the package's reported timer matches the manifest's pin"),
        None => result.report_warn(
            "the package does not report upgrade_timer_addr, so the timer is taken from the \
             manifest alone — a package produced before the prepare output named it",
        ),
    }

    // ── 7. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    verify_stage0_shape(&package, result);
    verify_stage1_shape(&package, &manifest, result);
    verify_stage2_shape(&package, result);

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
        for line in &package.external_actions {
            result.print_info(&format!("    · {line}"));
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

/// Stage 2 closes it, and asserts the edge actually applied. `validateApplied()` is the edge's
/// own post-condition check: a package that omits it can complete governance without ever
/// having proved the ecosystem reached the intended state.
fn verify_stage2_shape(package: &BootstrapPackage, result: &mut VerificationResult) {
    let asserts_applied = package.stage2.iter().any(|c| {
        c.target == package.migration && c.data.get(..4) == Some(&VALIDATE_APPLIED_SELECTOR[..])
    });
    if asserts_applied {
        result.report_ok("stage 2 asserts the edge applied (`validateApplied()` on the migration)");
    } else {
        result.report_warn(
            "stage 2 does not call `validateApplied()` on the migration: governance would \
             complete without the edge proving it reached the intended state",
        );
    }

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

/// Stage 1 of a bootstrap edge is a fixed, small shape: hand the CTM to the migration, hand its
/// ProxyAdmin to the migration, then `migrate()`. Anything else in that stage is a call a
/// reviewer has to justify, so it is reported rather than assumed benign.
fn verify_stage1_shape(
    package: &BootstrapPackage,
    manifest: &views::BootstrapManifest,
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
            if handed_to == manifest.ecosystemExecutor {
                // The ecosystem leg: the shared ProxyAdmin goes to the ecosystem executor, not
                // to the migration. Expected in any edge that carries a CoreRegistry.
                saw_ecosystem_admin_handover = true;
            } else if handed_to != migration {
                unexpected.push(format!(
                    "transferOwnership on {} hands to {handed_to}, which is neither the \
                     migration nor the ecosystem executor",
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
            if call.target == manifest.ecosystemExecutor {
                saw_apply_l1 = true;
            } else {
                unexpected.push(format!(
                    "applyL1Upgrade on {}, which is not the manifest's ecosystem executor",
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
            "stage 1 carries the ecosystem leg: the shared ProxyAdmin goes to the ecosystem \
             executor, which then applies the pinned inventory",
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
