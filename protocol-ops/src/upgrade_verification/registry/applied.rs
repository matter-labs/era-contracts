//! What a registry package must have left behind once its governance bundle ran, read from the
//! fork `ecosystem upgrade-governance` replayed it on. The contracts assert part of it themselves
//! (the bootstrap's `validateApplied()`, the CTM executor's check of its own commit); this holds
//! the whole post-state a second time, so a bundle that executed but did not land is caught here
//! too (`protocol-docs/ecosystem-upgrade.md#where-each-check-lives`).

use alloy::primitives::Address;
use alloy::providers::Provider;

use crate::upgrade_verification::constants::CTM_CONTRACT_SERVER_NOTIFIER_SLOT;
use crate::upgrade_verification::report::VerificationResult;

use super::format_semver;
use super::lifecycle::verify_executor_owners;
use super::package::{
    BootstrapPackage, LegKind, RegistryPackage, ReplacementPackage, UpgradePackage,
};
use super::provenance::tolerate;
use super::views::{
    CTMReleaseView, CTMTransitionView, CTMUpgradeExecutorView, CoreUpgradeExecutorView, CtmView,
    Ownable2StepView, ProxyAdminView, ProxyUpgradeRow, ProxyUpgradeTransitionView,
    RegistryBootstrapMigrationView, ServerNotifierView,
};

/// Holds the live state after `package`'s bundle executed against everything it must have left:
/// each unmet expectation, and each read that fails, is an ERROR. `governance` is the account
/// that executed the bundle; a bootstrap holds its executors to its manifest's governance instead.
pub(crate) async fn verify_applied<P: Provider>(
    provider: &P,
    package: &RegistryPackage,
    governance: Address,
    result: &mut VerificationResult,
) {
    match package {
        RegistryPackage::Upgrade(package) => {
            verify_upgrade_applied(provider, package, governance, result).await
        }
        RegistryPackage::Bootstrap(package) => {
            verify_bootstrap_applied(provider, package, result).await
        }
        RegistryPackage::Replacement(package) => {
            verify_replacement_applied(provider, package, governance, result).await
        }
    }
}

/// Reads, in order: each named executor's owner and pending owner (core first); for a core leg
/// the core executor's `PROXY_ADMIN()`, its owner and the core rows; for CTM legs the CTM
/// executor's bindings, the CTM domain ([`expect_ctm_domain_held`]), the infrastructure rows and
/// the transition's commitment ([`expect_transition_committed`]).
async fn verify_upgrade_applied<P: Provider>(
    provider: &P,
    package: &UpgradePackage,
    governance: Address,
    result: &mut VerificationResult,
) {
    let ctm_leg_executor = package
        .legs
        .iter()
        .find(|leg| leg.kind.is_ctm())
        .map(|leg| leg.executor);
    let named_core = package
        .leg(LegKind::Core)
        .map(|leg| leg.executor)
        .or(package.lifecycle.core_executor);
    let named_ctm = ctm_leg_executor.or(package.reported_ctm_executor);
    let executors: Vec<(&str, Address)> = named_core
        .map(|executor| ("the core executor", executor))
        .into_iter()
        .chain(named_ctm.map(|executor| ("the CTM executor", executor)))
        .collect();
    verify_executor_owners(
        provider,
        result,
        Some(governance),
        "the governance that executed the bundle",
        &executors,
    )
    .await;

    if let Some(leg) = package.leg(LegKind::Core) {
        if let Some(admin) = tolerate(
            CoreUpgradeExecutorView::new(leg.executor, provider)
                .PROXY_ADMIN()
                .call()
                .await,
            result,
            "the core executor's PROXY_ADMIN",
        ) {
            expect_owner(
                provider,
                result,
                "the ecosystem ProxyAdmin",
                admin,
                leg.executor,
                "the core executor",
            )
            .await;
            expect_transition_rows_applied(
                provider,
                result,
                "the core transition",
                leg.object,
                admin,
            )
            .await;
        }
    }

    let Some(ctm_executor) = ctm_leg_executor else {
        return;
    };
    let executor = CTMUpgradeExecutorView::new(ctm_executor, provider);
    let (Some(ctm), Some(ctm_admin)) = (
        tolerate(
            executor.CHAIN_TYPE_MANAGER().call().await,
            result,
            "the CTM executor's CHAIN_TYPE_MANAGER",
        ),
        tolerate(
            executor.CTM_PROXY_ADMIN().call().await,
            result,
            "the CTM executor's CTM_PROXY_ADMIN",
        ),
    ) else {
        return;
    };
    expect_ctm_domain_held(provider, result, ctm, ctm_admin, ctm_executor, None).await;
    if let Some(leg) = package.leg(LegKind::Infrastructure) {
        expect_transition_rows_applied(
            provider,
            result,
            "the CTM infrastructure transition",
            leg.object,
            ctm_admin,
        )
        .await;
    }
    if let Some(leg) = package.leg(LegKind::Transition) {
        expect_transition_committed(provider, result, ctm, leg.object).await;
    }
}

/// Reads, in order: the migration's manifest, `executed()` and `newProtocolVersion()`; the CTM's
/// version and release, and the release's own version; the CTM domain
/// ([`expect_ctm_domain_held`]); both executors' owners; the core executor's `PROXY_ADMIN()` and
/// its owner; the CTM rows, then the core transition's rows.
async fn verify_bootstrap_applied<P: Provider>(
    provider: &P,
    package: &BootstrapPackage,
    result: &mut VerificationResult,
) {
    let migration = RegistryBootstrapMigrationView::new(package.migration, provider);
    let Some(manifest) = tolerate(
        migration.getManifest().call().await,
        result,
        "the migration's manifest",
    ) else {
        return;
    };
    match tolerate(
        migration.executed().call().await,
        result,
        "the migration's executed()",
    ) {
        Some(true) => result.report_ok("the migration ran"),
        Some(false) => result.report_error(
            "the migration reports executed() == false: the bundle did not run the edge",
        ),
        None => {}
    }
    let ctm = CtmView::new(manifest.ctm, provider);
    let target = tolerate(
        migration.newProtocolVersion().call().await,
        result,
        "the migration's newProtocolVersion()",
    );
    let version = tolerate(
        ctm.protocolVersion().call().await,
        result,
        "the CTM's protocolVersion()",
    );
    if let (Some(target), Some(version)) = (target, version) {
        expect_equal(
            result,
            "the CTM's protocol version",
            format_semver(version),
            format_semver(target),
            "the edge's target",
        );
    }
    if let Some(release) = tolerate(
        ctm.currentRelease().call().await,
        result,
        "the CTM's currentRelease()",
    ) {
        expect_equal(
            result,
            "the CTM's current release",
            release,
            manifest.currentRelease,
            "the manifest's release",
        );
        expect_release_at_version(provider, result, release, version).await;
    }

    let notifier = manifest
        .ctmProxyUpgrades
        .get(CTM_CONTRACT_SERVER_NOTIFIER_SLOT)
        .map(|row| row.proxy);
    if notifier.is_none() {
        result.report_error(
            "the manifest carries no ServerNotifier slot, so the notifier the edge binds cannot \
             be read",
        );
    }
    expect_ctm_domain_held(
        provider,
        result,
        manifest.ctm,
        manifest.ctmProxyAdmin,
        manifest.ctmExecutor,
        notifier,
    )
    .await;
    verify_executor_owners(
        provider,
        result,
        Some(manifest.governance),
        "the manifest's governance",
        &[
            ("the core executor", manifest.coreExecutor),
            ("the CTM executor", manifest.ctmExecutor),
        ],
    )
    .await;
    let eco_admin = tolerate(
        CoreUpgradeExecutorView::new(manifest.coreExecutor, provider)
            .PROXY_ADMIN()
            .call()
            .await,
        result,
        "the core executor's PROXY_ADMIN",
    );
    if let Some(admin) = eco_admin {
        expect_owner(
            provider,
            result,
            "the ecosystem ProxyAdmin",
            admin,
            manifest.coreExecutor,
            "the core executor",
        )
        .await;
    }

    let ctm_rows: Vec<ProxyUpgradeRow> = manifest
        .ctmProxyUpgrades
        .into_iter()
        .filter(|row| !row.implNew.is_zero())
        .collect();
    expect_rows_applied(
        provider,
        result,
        "the migration's CTM-domain inventory",
        &ctm_rows,
        manifest.ctmProxyAdmin,
    )
    .await;
    if let (Some(core_transition), Some(admin)) = (package.core_transition, eco_admin) {
        expect_transition_rows_applied(
            provider,
            result,
            "the core transition",
            core_transition,
            admin,
        )
        .await;
    }
}

/// Reads, in order: the CTM executor's owner and pending owner, the replacement's
/// `oldProtocolVersion()`, the CTM's `upgradeTransition(departure)`, and — when the forward sets
/// a nonzero deadline — the CTM's `protocolVersionDeadline` of that version.
async fn verify_replacement_applied<P: Provider>(
    provider: &P,
    package: &ReplacementPackage,
    governance: Address,
    result: &mut VerificationResult,
) {
    let forward = &package.forward;
    verify_executor_owners(
        provider,
        result,
        Some(governance),
        "the governance that executed the bundle",
        &[("the CTM executor", forward.executor)],
    )
    .await;
    let ctm = CtmView::new(forward.ctm, provider);
    if let Some(departure) = tolerate(
        CTMTransitionView::new(forward.replacement, provider)
            .oldProtocolVersion()
            .call()
            .await,
        result,
        "the replacement's oldProtocolVersion()",
    ) {
        if let Some(committed) = tolerate(
            ctm.upgradeTransition(departure).call().await,
            result,
            "the CTM's upgradeTransition(departure)",
        ) {
            expect_equal(
                result,
                &format!(
                    "the transition committed for departures from {}",
                    format_semver(departure)
                ),
                committed,
                forward.replacement,
                "the replacement",
            );
        }
    }
    if let Some(change) = forward
        .deadline
        .filter(|change| !change.timestamp.is_zero())
    {
        if let Some(deadline) = tolerate(
            ctm.protocolVersionDeadline(change.protocol_version)
                .call()
                .await,
            result,
            "the CTM's protocolVersionDeadline",
        ) {
            expect_equal(
                result,
                &format!("the deadline of {}", format_semver(change.protocol_version)),
                deadline,
                change.timestamp,
                "the deadline the forward sets",
            );
        }
    }
}

/// The CTM domain landed under `executor`: the CTM owned by it with no nomination, its ProxyAdmin
/// owned by it, and the ServerNotifier — `expected_notifier` when the package names one, else the
/// CTM's — bound to the CTM and owned by it with no nomination.
///
/// Reads, in order: the CTM's owner and pending owner, the ProxyAdmin's owner, the CTM's
/// `serverNotifierAddress()`, then the notifier's owner, pending owner and `chainTypeManager()`.
async fn expect_ctm_domain_held<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    ctm: Address,
    ctm_admin: Address,
    executor: Address,
    expected_notifier: Option<Address>,
) {
    expect_owner(
        provider,
        result,
        "the CTM",
        ctm,
        executor,
        "the CTM executor",
    )
    .await;
    expect_no_pending_owner(provider, result, "the CTM", ctm).await;
    expect_owner(
        provider,
        result,
        "the CTM-domain ProxyAdmin",
        ctm_admin,
        executor,
        "the CTM executor",
    )
    .await;
    let bound = tolerate(
        CtmView::new(ctm, provider)
            .serverNotifierAddress()
            .call()
            .await,
        result,
        "the CTM's serverNotifierAddress()",
    );
    if let (Some(bound), Some(expected)) = (bound, expected_notifier) {
        expect_equal(
            result,
            "the CTM's ServerNotifier",
            bound,
            expected,
            "the manifest's ServerNotifier",
        );
    }
    let Some(notifier) = expected_notifier.or(bound) else {
        return;
    };
    expect_owner(
        provider,
        result,
        "the ServerNotifier",
        notifier,
        executor,
        "the CTM executor",
    )
    .await;
    expect_no_pending_owner(provider, result, "the ServerNotifier", notifier).await;
    if let Some(served) = tolerate(
        ServerNotifierView::new(notifier, provider)
            .chainTypeManager()
            .call()
            .await,
        result,
        "the ServerNotifier's chainTypeManager()",
    ) {
        expect_equal(
            result,
            "the CTM the ServerNotifier serves",
            served,
            ctm,
            "the CTM",
        );
    }
}

/// The transition is committed: the CTM moved to its target version and release and commits it
/// for its departure, and the installed release is at the CTM's version.
///
/// Reads, in order: the transition's old and new version and `newRelease()`; the CTM's version,
/// release and `upgradeTransition(departure)`; the release's own version.
async fn expect_transition_committed<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    ctm: Address,
    transition: Address,
) {
    let view = CTMTransitionView::new(transition, provider);
    let (Some(old_version), Some(new_version), Some(new_release)) = (
        tolerate(
            view.oldProtocolVersion().call().await,
            result,
            "the transition's oldProtocolVersion()",
        ),
        tolerate(
            view.newProtocolVersion().call().await,
            result,
            "the transition's newProtocolVersion()",
        ),
        tolerate(
            view.newRelease().call().await,
            result,
            "the transition's newRelease()",
        ),
    ) else {
        return;
    };
    let ctm_view = CtmView::new(ctm, provider);
    let version = tolerate(
        ctm_view.protocolVersion().call().await,
        result,
        "the CTM's protocolVersion()",
    );
    if let Some(version) = version {
        expect_equal(
            result,
            "the CTM's protocol version",
            format_semver(version),
            format_semver(new_version),
            "the transition's target",
        );
    }
    let release = tolerate(
        ctm_view.currentRelease().call().await,
        result,
        "the CTM's currentRelease()",
    );
    if let Some(release) = release {
        expect_equal(
            result,
            "the CTM's current release",
            release,
            new_release,
            "the transition's release",
        );
    }
    if let Some(committed) = tolerate(
        ctm_view.upgradeTransition(old_version).call().await,
        result,
        "the CTM's upgradeTransition(departure)",
    ) {
        expect_equal(
            result,
            &format!(
                "the transition committed for departures from {}",
                format_semver(old_version)
            ),
            committed,
            transition,
            "the transition",
        );
    }
    if let Some(release) = release {
        expect_release_at_version(provider, result, release, version).await;
    }
}

/// The installed release is at the CTM's version (`ctm_version`, `None` when unread): nothing on
/// chain compares them any more. Reads the release's `protocolVersion()`.
async fn expect_release_at_version<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    release: Address,
    ctm_version: Option<alloy::primitives::U256>,
) {
    let release_version = tolerate(
        CTMReleaseView::new(release, provider)
            .protocolVersion()
            .call()
            .await,
        result,
        "the current release's protocolVersion()",
    );
    if let (Some(release_version), Some(ctm_version)) = (release_version, ctm_version) {
        expect_equal(
            result,
            "the current release's version",
            format_semver(release_version),
            format_semver(ctm_version),
            "the CTM's version",
        );
    }
}

/// Every row `transition.rows()` applied runs its `implNew` behind `admin`.
async fn expect_transition_rows_applied<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    transition: Address,
    admin: Address,
) {
    if let Some(rows) = tolerate(
        ProxyUpgradeTransitionView::new(transition, provider)
            .rows()
            .call()
            .await,
        result,
        &format!("{label}'s rows()"),
    ) {
        expect_rows_applied(provider, result, label, &rows, admin).await;
    }
}

/// Reads each row's live implementation through `admin`, in row order.
async fn expect_rows_applied<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    rows: &[ProxyUpgradeRow],
    admin: Address,
) {
    let mut applied = 0usize;
    for row in rows {
        let Some(live) = tolerate(
            ProxyAdminView::new(admin, provider)
                .getProxyImplementation(row.proxy)
                .call()
                .await,
            result,
            &format!("the live implementation of {} under {admin}", row.proxy),
        ) else {
            continue;
        };
        if live == row.implNew {
            applied += 1;
        } else {
            result.report_error(&format!(
                "after the replay, {label}'s proxy {} runs {live}, not its implNew {}",
                row.proxy, row.implNew
            ));
        }
    }
    if applied == rows.len() {
        result.report_ok(&format!(
            "after the replay, each of {label}'s {applied} row(s) runs its implNew"
        ));
    }
}

async fn expect_owner<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    subject: Address,
    expected: Address,
    expected_label: &str,
) {
    if let Some(owner) = tolerate(
        Ownable2StepView::new(subject, provider)
            .owner()
            .call()
            .await,
        result,
        &format!("{label}'s owner"),
    ) {
        expect_equal(
            result,
            &format!("{label}'s owner"),
            owner,
            expected,
            expected_label,
        );
    }
}

async fn expect_no_pending_owner<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    subject: Address,
) {
    if let Some(pending) = tolerate(
        Ownable2StepView::new(subject, provider)
            .pendingOwner()
            .call()
            .await,
        result,
        &format!("{label}'s pending owner"),
    ) {
        expect_equal(
            result,
            &format!("{label}'s pending owner"),
            pending,
            Address::ZERO,
            "no nomination",
        );
    }
}

fn expect_equal<T: PartialEq + std::fmt::Display>(
    result: &mut VerificationResult,
    what: &str,
    live: T,
    expected: T,
    expected_label: &str,
) {
    if live == expected {
        result.report_ok(&format!(
            "after the replay, {what} is {expected_label} ({expected})"
        ));
    } else {
        result.report_error(&format!(
            "after the replay, {what} is {live}, not {expected_label} ({expected})"
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{Bytes, U256};
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    use super::super::package::{
        recover_legs, DeadlineChange, LifecycleInputs, RecoveredReplacement,
    };
    use super::super::views::{AuthoredL2Plan, BootstrapManifest};
    use crate::common::governance_calls::GovernanceCall;
    use crate::upgrade_verification::constants::CTM_CONTRACTS;

    const GOVERNANCE: Address = Address::repeat_byte(0x60);
    const CORE_EXECUTOR: Address = Address::repeat_byte(0xE0);
    const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);
    const CORE_TRANSITION: Address = Address::repeat_byte(0xEE);
    const INFRASTRUCTURE: Address = Address::repeat_byte(0x1F);
    const TRANSITION: Address = Address::repeat_byte(0xCC);
    const MIGRATION: Address = Address::repeat_byte(0x3B);
    const CTM: Address = Address::repeat_byte(0xC7);
    const CTM_ADMIN: Address = Address::repeat_byte(0xA7);
    const ECO_ADMIN: Address = Address::repeat_byte(0xA0);
    const NOTIFIER: Address = Address::repeat_byte(0x5E);
    const R36: Address = Address::repeat_byte(0x36);
    const PROXY: Address = Address::repeat_byte(0x70);
    const OLD: Address = Address::repeat_byte(0x01);
    const NEW: Address = Address::repeat_byte(0x02);
    const STRANGER: Address = Address::repeat_byte(0x99);
    const V35: u64 = 0x23_0000_0000;
    const V36: u64 = 0x24_0000_0000;

    /// The answers the node gives, in read order, each named so a test can change one. `None`
    /// is a reverting read.
    struct Reads(Vec<(&'static str, Option<Bytes>)>);

    impl Reads {
        fn new() -> Self {
            Self(Vec::new())
        }

        fn answer(mut self, label: &'static str, value: impl SolValue) -> Self {
            self.0.push((label, Some(Bytes::from(value.abi_encode()))));
            self
        }

        fn set(mut self, label: &str, value: impl SolValue) -> Self {
            let slot = self.slot(label);
            slot.1 = Some(Bytes::from(value.abi_encode()));
            self
        }

        fn revert(mut self, label: &str) -> Self {
            self.slot(label).1 = None;
            self
        }

        fn slot(&mut self, label: &str) -> &mut (&'static str, Option<Bytes>) {
            self.0
                .iter_mut()
                .find(|(name, _)| *name == label)
                .unwrap_or_else(|| panic!("no read named {label}"))
        }
    }

    async fn run(package: &RegistryPackage, reads: Reads) -> VerificationResult {
        let asserter = Asserter::new();
        for (_, answer) in &reads.0 {
            match answer {
                Some(answer) => asserter.push_success(answer),
                None => asserter.push_failure_msg("execution reverted"),
            }
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_applied(&provider, package, GOVERNANCE, &mut result).await;
        assert!(
            asserter.read_q().is_empty(),
            "every read was made, in the documented order"
        );
        result
    }

    fn row(proxy: Address) -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy,
            expectedOldImpl: OLD,
            implNew: NEW,
            callInitializeUpgrade: false,
        }
    }

    /// Runs `reads` with each change in `cases` applied alone: each must fail with exactly one
    /// error naming `needle`.
    async fn each_unmet_expectation_fails(
        package: &RegistryPackage,
        reads: fn() -> Reads,
        cases: Vec<(&str, Reads, &str)>,
    ) {
        assert_eq!(run(package, reads()).await.errors, 0, "the landed state");
        for (case, reads, needle) in cases {
            let result = run(package, reads).await;
            assert_eq!(result.errors, 1, "{case}: {:?}", result.error_messages);
            assert!(
                result.has_error(needle),
                "{case}: {:?}",
                result.error_messages
            );
        }
    }

    // ───────────────────────── an upgrade ─────────────────────────

    fn upgrade() -> RegistryPackage {
        let calls: Vec<GovernanceCall> = [
            (LegKind::Core, CORE_EXECUTOR, CORE_TRANSITION),
            (LegKind::Infrastructure, CTM_EXECUTOR, INFRASTRUCTURE),
            (LegKind::Transition, CTM_EXECUTOR, TRANSITION),
        ]
        .into_iter()
        .map(|(kind, executor, object)| GovernanceCall {
            target: executor,
            value: U256::ZERO,
            data: kind.encode(object),
        })
        .collect();
        RegistryPackage::Upgrade(UpgradePackage {
            legs: recover_legs(&calls).unwrap(),
            ctm_key: Some("zksync_os".to_string()),
            reported_core_transition: Some(CORE_TRANSITION),
            reported_infrastructure_transition: Some(INFRASTRUCTURE),
            reported_ctm_transition: Some(TRANSITION),
            reported_ctm_executor: Some(CTM_EXECUTOR),
            reported_ctm: Some(CTM),
            reported_ctm_proxy_admin: Some(CTM_ADMIN),
            reported_singletons: Default::default(),
            calls,
            external_actions: Vec::new(),
            create2_salts: Vec::new(),
            lifecycle: LifecycleInputs {
                core_executor: Some(CORE_EXECUTOR),
                core_proxy_admin: Some(ECO_ADMIN),
            },
            force_deployments_data: None,
            executor_records: Default::default(),
            member_records: Default::default(),
        })
    }

    /// The landed state of a three-leg upgrade, in the order `verify_upgrade_applied` reads it.
    fn upgrade_reads() -> Reads {
        Reads::new()
            .answer("coreExecutor.owner", GOVERNANCE)
            .answer("coreExecutor.pendingOwner", Address::ZERO)
            .answer("ctmExecutor.owner", GOVERNANCE)
            .answer("ctmExecutor.pendingOwner", Address::ZERO)
            .answer("coreExecutor.PROXY_ADMIN", ECO_ADMIN)
            .answer("ecoAdmin.owner", CORE_EXECUTOR)
            .answer("coreTransition.rows", vec![row(PROXY)])
            .answer("coreRow.implementation", NEW)
            .answer("ctmExecutor.CHAIN_TYPE_MANAGER", CTM)
            .answer("ctmExecutor.CTM_PROXY_ADMIN", CTM_ADMIN)
            .answer("ctm.owner", CTM_EXECUTOR)
            .answer("ctm.pendingOwner", Address::ZERO)
            .answer("ctmAdmin.owner", CTM_EXECUTOR)
            .answer("ctm.serverNotifierAddress", NOTIFIER)
            .answer("notifier.owner", CTM_EXECUTOR)
            .answer("notifier.pendingOwner", Address::ZERO)
            .answer("notifier.chainTypeManager", CTM)
            .answer("infrastructure.rows", vec![row(PROXY)])
            .answer("infrastructureRow.implementation", NEW)
            .answer("transition.oldProtocolVersion", U256::from(V35))
            .answer("transition.newProtocolVersion", U256::from(V36))
            .answer("transition.newRelease", R36)
            .answer("ctm.protocolVersion", U256::from(V36))
            .answer("ctm.currentRelease", R36)
            .answer("ctm.upgradeTransition", TRANSITION)
            .answer("release.protocolVersion", U256::from(V36))
    }

    /// x.ctm-10..12: what `validateTransitionApplied` asserted, and the domains the legs ran
    /// through, read after the replay — each unmet expectation is an error of its own.
    #[tokio::test]
    async fn an_upgrade_that_did_not_land_fails() {
        let r = upgrade_reads;
        each_unmet_expectation_fails(
            &upgrade(),
            r,
            vec![
                (
                    "version",
                    r().set("ctm.protocolVersion", U256::from(V35))
                        .set("release.protocolVersion", U256::from(V35)),
                    "the CTM's protocol version is v0.35.0, not the transition's target",
                ),
                (
                    "release",
                    r().set("ctm.currentRelease", STRANGER),
                    "the CTM's current release",
                ),
                (
                    "commitment",
                    r().set("ctm.upgradeTransition", STRANGER),
                    "the transition committed for departures from v0.35.0",
                ),
                (
                    "release version",
                    r().set("release.protocolVersion", U256::from(V35)),
                    "the current release's version",
                ),
                (
                    "CTM owner",
                    r().set("ctm.owner", STRANGER),
                    "the CTM's owner",
                ),
                (
                    "CTM nomination",
                    r().set("ctm.pendingOwner", STRANGER),
                    "the CTM's pending owner",
                ),
                (
                    "CTM ProxyAdmin",
                    r().set("ctmAdmin.owner", GOVERNANCE),
                    "the CTM-domain ProxyAdmin's owner",
                ),
                (
                    "notifier owner",
                    r().set("notifier.owner", STRANGER),
                    "the ServerNotifier's owner",
                ),
                (
                    "notifier nomination",
                    r().set("notifier.pendingOwner", STRANGER),
                    "the ServerNotifier's pending owner",
                ),
                (
                    "notifier CTM",
                    r().set("notifier.chainTypeManager", STRANGER),
                    "the CTM the ServerNotifier serves",
                ),
                (
                    "ecosystem ProxyAdmin",
                    r().set("ecoAdmin.owner", GOVERNANCE),
                    "the ecosystem ProxyAdmin's owner",
                ),
                (
                    "core row",
                    r().set("coreRow.implementation", OLD),
                    "the core transition's proxy",
                ),
                (
                    "infrastructure row",
                    r().set("infrastructureRow.implementation", OLD),
                    "the CTM infrastructure transition's proxy",
                ),
                (
                    "executor owner",
                    r().set("coreExecutor.owner", STRANGER),
                    "the governance that executed the bundle",
                ),
                (
                    "executor nomination",
                    r().set("ctmExecutor.pendingOwner", STRANGER),
                    "has a pending owner",
                ),
                (
                    "unreadable",
                    r().revert("ctm.upgradeTransition"),
                    "could not be read",
                ),
            ],
        )
        .await;
    }

    /// A core-only upgrade reads no CTM domain.
    #[tokio::test]
    async fn a_core_only_upgrade_reads_only_its_domain() {
        let RegistryPackage::Upgrade(mut package) = upgrade() else {
            unreachable!()
        };
        package.legs.retain(|leg| leg.kind == LegKind::Core);
        package.reported_ctm_executor = None;
        let reads = Reads::new()
            .answer("coreExecutor.owner", GOVERNANCE)
            .answer("coreExecutor.pendingOwner", Address::ZERO)
            .answer("coreExecutor.PROXY_ADMIN", ECO_ADMIN)
            .answer("ecoAdmin.owner", CORE_EXECUTOR)
            .answer("coreTransition.rows", vec![row(PROXY)])
            .answer("coreRow.implementation", NEW);
        let result = run(&RegistryPackage::Upgrade(package), reads).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
    }

    // ───────────────────────── the bootstrap ─────────────────────────

    fn manifest() -> BootstrapManifest {
        let mut rows = vec![
            ProxyUpgradeRow {
                proxy: Address::ZERO,
                expectedOldImpl: Address::ZERO,
                implNew: Address::ZERO,
                callInitializeUpgrade: false,
            };
            CTM_CONTRACTS.len()
        ];
        rows[CTM_CONTRACTS
            .iter()
            .position(|m| *m == "ChainTypeManager")
            .unwrap()] = row(CTM);
        rows[CTM_CONTRACT_SERVER_NOTIFIER_SLOT] = row(NOTIFIER);
        BootstrapManifest {
            ctm: CTM,
            expectedProtocolVersion: U256::from(V35),
            ctmProxyAdmin: CTM_ADMIN,
            ctmProxyUpgrades: rows,
            currentRelease: R36,
            oldProtocolVersionDeadline: U256::MAX,
            upgradeEngine: Address::repeat_byte(0xEA),
            l2Plan: AuthoredL2Plan {
                delegateBytecodeInfo: Bytes::new(),
                extraBytecodeInfos: Vec::new(),
                delegateComposer: Address::ZERO,
            },
            upgradeTimestamp: U256::ZERO,
            ctmExecutor: CTM_EXECUTOR,
            coreExecutor: CORE_EXECUTOR,
            governance: GOVERNANCE,
        }
    }

    fn bootstrap() -> RegistryPackage {
        RegistryPackage::Bootstrap(BootstrapPackage {
            core_transition: Some(CORE_TRANSITION),
            release: R36,
            migration: MIGRATION,
            reported_migration: Some(MIGRATION),
            reported_ctm_executor: Some(CTM_EXECUTOR),
            reported_ctm: Some(CTM),
            reported_ctm_proxy_admin: Some(CTM_ADMIN),
            reported_singletons: Default::default(),
            ctm_key: "zksync_os".to_string(),
            calls: Vec::new(),
            external_actions: Vec::new(),
            create2_salts: Vec::new(),
            lifecycle: Default::default(),
            force_deployments_data: None,
            executor_records: Default::default(),
            member_records: Default::default(),
        })
    }

    /// The landed edge, in the order `verify_bootstrap_applied` reads it.
    fn bootstrap_reads() -> Reads {
        Reads::new()
            .answer("migration.getManifest", manifest())
            .answer("migration.executed", true)
            .answer("migration.newProtocolVersion", U256::from(V36))
            .answer("ctm.protocolVersion", U256::from(V36))
            .answer("ctm.currentRelease", R36)
            .answer("release.protocolVersion", U256::from(V36))
            .answer("ctm.owner", CTM_EXECUTOR)
            .answer("ctm.pendingOwner", Address::ZERO)
            .answer("ctmAdmin.owner", CTM_EXECUTOR)
            .answer("ctm.serverNotifierAddress", NOTIFIER)
            .answer("notifier.owner", CTM_EXECUTOR)
            .answer("notifier.pendingOwner", Address::ZERO)
            .answer("notifier.chainTypeManager", CTM)
            .answer("coreExecutor.owner", GOVERNANCE)
            .answer("coreExecutor.pendingOwner", Address::ZERO)
            .answer("ctmExecutor.owner", GOVERNANCE)
            .answer("ctmExecutor.pendingOwner", Address::ZERO)
            .answer("coreExecutor.PROXY_ADMIN", ECO_ADMIN)
            .answer("ecoAdmin.owner", CORE_EXECUTOR)
            .answer("ctmRow.implementation", NEW)
            .answer("notifierRow.implementation", NEW)
            .answer("coreTransition.rows", vec![row(PROXY)])
            .answer("coreRow.implementation", NEW)
    }

    /// boot-49..55: what `validateApplied` asserts on chain, read again after the replay.
    #[tokio::test]
    async fn a_bootstrap_that_did_not_land_fails() {
        let r = bootstrap_reads;
        each_unmet_expectation_fails(
            &bootstrap(),
            r,
            vec![
                (
                    "not executed",
                    r().set("migration.executed", false),
                    "executed() == false",
                ),
                (
                    "version",
                    r().set("ctm.protocolVersion", U256::from(V35))
                        .set("release.protocolVersion", U256::from(V35)),
                    "the CTM's protocol version is v0.35.0, not the edge's target",
                ),
                (
                    "release",
                    r().set("ctm.currentRelease", STRANGER),
                    "not the manifest's release",
                ),
                (
                    "release version",
                    r().set("release.protocolVersion", U256::from(V35)),
                    "the current release's version",
                ),
                (
                    "CTM left with the migration",
                    r().set("ctm.owner", MIGRATION),
                    "the CTM's owner",
                ),
                (
                    "CTM nomination",
                    r().set("ctm.pendingOwner", CTM_EXECUTOR),
                    "the CTM's pending owner",
                ),
                (
                    "CTM ProxyAdmin",
                    r().set("ctmAdmin.owner", MIGRATION),
                    "the CTM-domain ProxyAdmin's owner",
                ),
                (
                    "notifier re-pointed",
                    r().set("ctm.serverNotifierAddress", STRANGER),
                    "not the manifest's ServerNotifier",
                ),
                (
                    "notifier owner",
                    r().set("notifier.owner", STRANGER),
                    "the ServerNotifier's owner",
                ),
                (
                    "notifier nomination",
                    r().set("notifier.pendingOwner", STRANGER),
                    "the ServerNotifier's pending owner",
                ),
                (
                    "notifier CTM",
                    r().set("notifier.chainTypeManager", STRANGER),
                    "the CTM the ServerNotifier serves",
                ),
                (
                    "executor owner",
                    r().set("ctmExecutor.owner", STRANGER),
                    "the manifest's governance",
                ),
                (
                    "executor nomination",
                    r().set("coreExecutor.pendingOwner", STRANGER),
                    "has a pending owner",
                ),
                (
                    "ecosystem ProxyAdmin",
                    r().set("ecoAdmin.owner", GOVERNANCE),
                    "the ecosystem ProxyAdmin's owner",
                ),
                (
                    "CTM row",
                    r().set("ctmRow.implementation", OLD),
                    "the migration's CTM-domain inventory's proxy",
                ),
                (
                    "core row",
                    r().set("coreRow.implementation", OLD),
                    "the core transition's proxy",
                ),
            ],
        )
        .await;
    }

    // ───────────────────────── a replacement ─────────────────────────

    const REPLACEMENT: Address = Address::repeat_byte(0xB4);
    const DEADLINE: u64 = 1_900_000_000;

    fn replacement(deadline: Option<DeadlineChange>) -> RegistryPackage {
        RegistryPackage::Replacement(Box::new(ReplacementPackage {
            forward: RecoveredReplacement {
                index: 0,
                executor: CTM_EXECUTOR,
                ctm: CTM,
                expected: TRANSITION,
                replacement: REPLACEMENT,
                deadline,
            },
            ctm_key: "zksync_os".to_string(),
            reported_replaced: None,
            reported_replacement: None,
            reported_ctm_transition: None,
            reported_release: None,
            reported_ctm_executor: None,
            reported_ctm: None,
            reported_ctm_proxy_admin: None,
            calls: Vec::new(),
            external_actions: Vec::new(),
            create2_salts: Vec::new(),
            reported_old_version: None,
            reported_new_version: None,
            executor_records: Default::default(),
            member_records: Default::default(),
        }))
    }

    fn replacement_reads() -> Reads {
        Reads::new()
            .answer("ctmExecutor.owner", GOVERNANCE)
            .answer("ctmExecutor.pendingOwner", Address::ZERO)
            .answer("replacement.oldProtocolVersion", U256::from(V35))
            .answer("ctm.upgradeTransition", REPLACEMENT)
    }

    /// The CTM commits the replacement for its departure; a deadline the forward moves is the
    /// CTM's after it.
    #[tokio::test]
    async fn a_replacement_that_did_not_land_fails() {
        let r = replacement_reads;
        each_unmet_expectation_fails(
            &replacement(None),
            r,
            vec![(
                "still the replaced transition",
                r().set("ctm.upgradeTransition", TRANSITION),
                "the transition committed for departures from v0.35.0",
            )],
        )
        .await;

        let moved = replacement(Some(DeadlineChange {
            protocol_version: U256::from(V35),
            timestamp: U256::from(DEADLINE),
        }));
        let with_deadline = |deadline: u64| {
            replacement_reads().answer("ctm.protocolVersionDeadline", U256::from(deadline))
        };
        assert_eq!(run(&moved, with_deadline(DEADLINE)).await.errors, 0);
        let result = run(&moved, with_deadline(DEADLINE - 1)).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("the deadline of v0.35.0"));

        // A cleared override is not read back: the getter then falls back to the pin.
        let cleared = replacement(Some(DeadlineChange {
            protocol_version: U256::from(V35),
            timestamp: U256::ZERO,
        }));
        assert_eq!(run(&cleared, replacement_reads()).await.errors, 0);
    }
}
