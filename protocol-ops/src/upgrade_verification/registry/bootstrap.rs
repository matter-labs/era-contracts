//! Verification of the one-time BOOTSTRAP edge onto the registry model.
//!
//! This is the only version-specific verifier in the tree, and it is version-specific because the
//! thing it verifies happens exactly once: a CTM that predates the registry model is handed to a
//! `CTMUpgradeExecutor`, and from then on every upgrade of that CTM is an ordinary operation
//! ([`super::operation`]). There is no second bootstrap to generalise over.
//!
//! Two things follow from an edge having no executor to invoke yet:
//!
//! * governance executes a LIST of ordinary calls rather than `execute(operation)`, so the list has
//!   to be compared against the one `RegistryBootstrapSequence` derives — see
//!   [`verify_derived_sequence`], which says why that comparison is transitional scaffolding and
//!   must not be generalised. The list is ONE bundle ending in the edge's completion check
//!   (`RegistryBootstrapMigration.validateApplied()`), so an edge that does not complete reverts
//!   the whole bundle;
//! * the objects it names (`RegistryBootstrapMigration`, the bootstrap sequence) exist only for
//!   this edge, and so do the views and checks below.
//!
//! Every object the edge names is held against its construction before anything it answers is
//! relied on — the write-once objects from the manifests they serve, the lifecycle objects
//! ([`super::lifecycle`]) and the sequence from the reviewed values they were built over. The
//! sequence in particular is the oracle the bundle is compared against, and an oracle the package
//! chose is worth nothing until the reviewed creation code is shown to have produced it.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::{SolCall, SolValue};

use crate::common::external_actions::{ExternalAction, GOVERNANCE_PHASE};
use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::constants::{
    CTM_CONTRACT_SERVER_NOTIFIER_SLOT, EIP1967_PROXY_ADMIN_SLOT,
};
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{
    canonical_create2_address, constructor_args, expect_canonical_construction, ReviewedBuild,
};
use super::genesis::ReviewedGenesis;
use super::lifecycle::{verify_lifecycle_construction, LifecycleBindings, LifecycleReview};
use super::members::{verify_engine_and_l2_plan, DepartingVerifiers, BOOTSTRAP_ENGINES};
use super::operation::{cross_check, verify_core_transition, verify_release};
use super::package::BootstrapPackage;
use super::provenance::{expect_code_identity, tolerate};
use super::rows::{participating, verify_inventory, Inventory, InventoryReview};
use super::views::{
    self, BootstrapCall, BridgehubView, CTMUpgradeExecutorView, CoreUpgradeExecutorView, CtmView,
    EcosystemUpgradeExecutorView, RegistryBootstrapMigrationView, ServerNotifierView,
    ZkChainGettersView,
};
use super::{format_semver, render_derived_payloads};

/// Verify the one-time bootstrap edge onto the registry model.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
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
        "bootstrap edge on CTM section [{}]: migration {} (from the bundle's `migrate()` call)",
        package.ctm_key, package.migration
    ));
    match package.reported_migration {
        Some(reported) if reported == package.migration => {
            result.report_ok("the reported bootstrap_migration_addr matches the executable calls")
        }
        Some(reported) => result.report_error(&format!(
            "the package reports bootstrap_migration_addr {reported} but the bundle calls \
             `migrate()` on {}: the summary and the executable calls describe different edges",
            package.migration
        )),
        None => result.report_warn(
            "the package does not report bootstrap_migration_addr, so the migration is known \
             only from the bundle's calldata",
        ),
    }

    // ── 1. The migration itself, and its committed manifest ──
    result.print_info("\n== Object provenance ==");
    expect_code_identity(
        provider,
        build,
        result,
        "the bootstrap migration",
        package.migration,
        &["RegistryBootstrapMigration"],
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
            "core_upgrade_executor_addr",
            package.lifecycle.core_executor,
            manifest.coreExecutor,
            "the core executor",
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
    let mut genesis = genesis.clone();
    genesis
        .force_deployments
        .read_live(
            provider,
            Some(manifest.ctm),
            Some(manifest.governance),
            "the manifest's governance",
        )
        .await;
    // A pre-registry CTM has no release to depart from: the verifier already in force is the
    // one its chains at the departing version run.
    let chains = read_chain_versions(
        provider,
        result,
        manifest.ctm,
        manifest.expectedProtocolVersion,
    )
    .await;
    let departing = DepartingVerifiers::new(
        "the verifier the CTM's chains at the departing version run",
        chains.iter().filter_map(|chain| chain.verifier).collect(),
    );
    verify_release(
        provider,
        build,
        &genesis,
        result,
        "the release the edge installs",
        manifest.currentRelease,
        salts,
        &departing,
        &mut reviewed,
    )
    .await?;
    let core_rows = match package.core_transition {
        Some(core_transition_addr) => Some(
            verify_core_transition(
                provider,
                build,
                result,
                core_transition_addr,
                salts,
                &mut reviewed,
            )
            .await?,
        ),
        None => None,
    };

    // The owner is the manifest's: the edge hands both domains to executors that answer to it,
    // and it is cross-checked against the reviewed governance address below.
    judge_executor_records_against_manifest(result, &package.executor_records, &manifest);
    let bindings = verify_lifecycle_construction(
        provider,
        build,
        result,
        &LifecycleReview {
            owner: Some(manifest.governance),
            coordinator: manifest.coordinator,
            core_executor: Some(manifest.coreExecutor),
            core_proxy_admin: package.lifecycle.core_proxy_admin,
            ctm_executor: manifest.ctmExecutor,
            ctm: Some(manifest.ctm),
            ctm_proxy_admin: Some(manifest.ctmProxyAdmin),
            records: package.executor_records.clone(),
        },
        &mut reviewed,
    )
    .await?;
    let sequence = locate_sequence(provider, build, result, package, salts, &mut reviewed).await?;
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

    // ── 2. The members the manifest names run the reviewed code ──
    result.print_info("\n== Named members ==");
    verify_engine_and_l2_plan(
        provider,
        build,
        result,
        "the bootstrap migration",
        manifest.upgradeEngine,
        BOOTSTRAP_ENGINES,
        &manifest.l2Plan,
    )
    .await?;

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

    // Every executor the edge binds answers to the manifest's governance with no nomination
    // outstanding (`migrate()` refuses anything else), and the two bindings the bundle sets are
    // still unset or already the manifest's.
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
        manifest.governance,
    );
    let coordinator_ctm_executor = tolerate(
        coordinator.ctmExecutor().call().await,
        result,
        "the coordinator's ctmExecutor()",
    );
    expect_bound_or_unset(
        result,
        "the coordinator's CTM executor",
        coordinator_ctm_executor,
        manifest.ctmExecutor,
        "`setCTMExecutor`",
    );
    let core_executor = CoreUpgradeExecutorView::new(manifest.coreExecutor, provider);
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
        manifest.governance,
    );
    let core_executor_coordinator = tolerate(
        core_executor.coordinator().call().await,
        result,
        "the core executor's coordinator",
    );
    expect_bound_or_unset(
        result,
        "the core executor's coordinator",
        core_executor_coordinator,
        manifest.coordinator,
        "`setCoordinator`",
    );

    // The manifest states the owner every executor must already have, and the migration refuses
    // to run otherwise. Verifying it here catches a wrong owner BEFORE governance signs — after
    // `migrate()` both domains are that owner's permanently.
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
        "the CTM executor",
        executor_owner,
        executor_pending_owner,
        manifest.governance,
    );

    match expected_governance_owner {
        Some(expected) if expected == manifest.governance => {
            result.report_ok(&format!(
                "the manifest's governance is the reviewed governance address {expected}"
            ));
        }
        Some(expected) => {
            result.report_error(&format!(
                "the manifest binds the executors to governance {} but the reviewed governance \
                 address is {expected}",
                manifest.governance
            ));
        }
        None => result.report_warn(
            "no --expected-governance-owner supplied: the governance both domains land on is \
             unverified against the review",
        ),
    }

    // ── 4. The one-time ServerNotifier handover: a precondition of the edge, half of which
    //    governance cannot perform ──
    result.print_info("\n== Prerequisite: ServerNotifier handover ==");
    let handover = verify_notifier_handover(provider, result, &manifest, &package.calls).await?;

    // ── 5. The departing state the manifest asserts ──
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

    // The target version is the genesis release's own; the migration serves it.
    let Some(new_version) = tolerate(
        migration.newProtocolVersion().call().await,
        result,
        "the migration's newProtocolVersion()",
    ) else {
        return Ok(());
    };
    if new_version > live_version {
        result.report_ok(&format!(
            "the target version {} is ahead of live",
            format_semver(new_version)
        ));
    } else {
        result.report_error(&format!(
            "the target version {} does not move forward from live {}",
            format_semver(new_version),
            format_semver(live_version)
        ));
    }

    // The bundle nominates the migration as CTM owner; before it nobody may be nominated, or the
    // edge's own handover would be racing an outstanding one.
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

    // Each CTM-domain row must name its slot's proxy and depart from the implementation that is
    // LIVE, not from whatever the prepare saw: a row at an unexpected implementation reverts the
    // bundle wholesale.
    verify_inventory(
        provider,
        build,
        result,
        &InventoryReview {
            inventory: Inventory::CtmDomain,
            rows: &manifest.ctmProxyUpgrades,
            domain_admin: manifest.ctmProxyAdmin,
            anchor: Some(manifest.ctm),
            departure_unreadable: (!handover.under_ctm_proxy_admin)
                .then_some(CTM_CONTRACT_SERVER_NOTIFIER_SLOT),
        },
    )
    .await?;

    // ── 6. Chains the edge leaves behind ──
    result.print_info("\n== Chains below the departing version ==");
    judge_lagging_chains(result, manifest.expectedProtocolVersion, &chains);

    // ── 7. The ecosystem leg ──
    result.print_info("\n== Ecosystem leg ==");
    // An unreadable core transition was reported when it was read, and leaves no rows to judge.
    if let Some(core_rows) = core_rows.as_ref().filter(|rows| participating(rows) > 0) {
        let Some(eco_admin_addr) = bindings.core_proxy_admin else {
            result.report_error(
                "the ecosystem ProxyAdmin is unknown (the core executor's PROXY_ADMIN could not \
                 be read), so the ecosystem rows cannot be held against live",
            );
            return Ok(());
        };
        let bridgehub = tolerate(
            ctm.BRIDGE_HUB().call().await,
            result,
            "the CTM's BRIDGE_HUB(), through which the ecosystem rows' proxies are discovered",
        );
        verify_inventory(
            provider,
            build,
            result,
            &InventoryReview {
                inventory: Inventory::Ecosystem,
                rows: core_rows,
                domain_admin: eco_admin_addr,
                anchor: bridgehub,
                departure_unreadable: None,
            },
        )
        .await?;
    } else if core_rows.is_none() {
        result.report_ok("no core transition: this edge upgrades no shared singletons");
    }

    // ── 8. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    let authorities = edge_authorities(
        &manifest,
        &bindings,
        sequence,
        package.core_transition,
        &reviewed,
    );
    verify_derived_sequence(provider, result, package, sequence, &authorities).await;

    // A bootstrap edge legitimately declares external actions — the derived sequence itself
    // rides as declared actions, and so do the merge's extras. They are the reviewable list,
    // so they are PRINTED rather than flagged; what the bundle check above flags is anything
    // that is neither derived nor declared, or that reaches an authority outside the sequence.
    if package.external_actions.is_empty() {
        result.report_warn(
            "the prepare declared NO external actions, which a bootstrap edge cannot be: its \
             handovers are not describable by any object",
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

/// The bootstrap prepare deploys the executors it hands the domains to, so their records describe
/// the manifest's own objects: each must name the manifest's address, and the CTM executor must
/// have been constructed with the manifest's coordinator. (The immutables are held against the
/// manifest by the lifecycle construction check.)
fn judge_executor_records_against_manifest(
    result: &mut VerificationResult,
    records: &UpgradeExecutorsRecord,
    manifest: &views::BootstrapManifest,
) {
    if records.is_empty() {
        result.print_info(
            "  the package carries no executor records, though the bootstrap prepare writes them: \
             each executor's construction needs one (reported below)",
        );
        return;
    }
    let mut check = |what: &str, recorded: Address, expected: Address, field: &str| {
        if recorded == expected {
            result.report_ok(&format!(
                "the executor record's {what} is the manifest's {field} {expected}"
            ));
        } else {
            result.report_error(&format!(
                "the executor record's {what} is {recorded} but the manifest's {field} is \
                 {expected}: the record describes another deployment than the edge hands over to"
            ));
        }
    };
    if let Some(record) = &records.core_executor {
        check(
            "core executor",
            record.address,
            manifest.coreExecutor,
            "coreExecutor",
        );
    }
    if let Some(record) = &records.coordinator {
        check(
            "coordinator",
            record.address,
            manifest.coordinator,
            "coordinator",
        );
    }
    if let Some(record) = &records.ctm_executor {
        check(
            "CTM executor",
            record.address,
            manifest.ctmExecutor,
            "ctmExecutor",
        );
        check(
            "CTM executor's constructor coordinator",
            record.coordinator,
            manifest.coordinator,
            "coordinator",
        );
    }
}

/// One chain registered on the CTM, as the lagging-chain report and the departing verifier read
/// it.
#[derive(Debug)]
struct ChainVersion {
    chain_id: U256,
    /// `None` when the CTM could not answer for the chain (already reported).
    protocol_version: Option<U256>,
    /// The verifier the chain runs, read only for a chain at the departing version; `None`
    /// otherwise or when unreadable (already reported).
    verifier: Option<Address>,
}

/// Every chain the CTM's Bridgehub registers on `ctm`, with its protocol version and, for a chain
/// at `departing`, the verifier it runs.
///
/// Reads, in order: the CTM's `BRIDGE_HUB()`, the Bridgehub's `getAllZKChainChainIDs()`, then per
/// chain `chainTypeManager(id)` and, for the CTM's own chains, the CTM's `getProtocolVersion(id)`
/// — and at the departing version the Bridgehub's `getZKChain(id)` and the chain's
/// `getVerifier()`. The reads are informational, so a failed one is a warning rather than an
/// error: an unread verifier only withholds the carry-over, and the release's verifier then fails
/// on its own.
async fn read_chain_versions<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    ctm: Address,
    departing: U256,
) -> Vec<ChainVersion> {
    let not_enumerable = |result: &mut VerificationResult, e: &dyn std::fmt::Display| {
        result.report_warn(&format!(
            "the chains on the CTM cannot be enumerated ({e}): no chain is reported as lagging, \
             which is not the same as none lagging"
        ));
    };
    let ctm_view = CtmView::new(ctm, provider);
    let bridgehub = match ctm_view.BRIDGE_HUB().call().await {
        Ok(bridgehub) => BridgehubView::new(bridgehub, provider),
        Err(e) => {
            not_enumerable(result, &e);
            return Vec::new();
        }
    };
    let chain_ids = match bridgehub.getAllZKChainChainIDs().call().await {
        Ok(ids) => ids,
        Err(e) => {
            not_enumerable(result, &e);
            return Vec::new();
        }
    };
    let mut chains = Vec::new();
    for chain_id in chain_ids {
        match bridgehub.chainTypeManager(chain_id).call().await {
            Ok(chain_ctm) if chain_ctm == ctm => {}
            Ok(_) => continue,
            Err(e) => {
                result.report_warn(&format!(
                    "chain {chain_id}: its CTM could not be read ({e}), so it is left out of the \
                     lagging-chain report"
                ));
                continue;
            }
        }
        let protocol_version = match ctm_view.getProtocolVersion(chain_id).call().await {
            Ok(version) => Some(version),
            Err(e) => {
                result.report_warn(&format!(
                    "chain {chain_id}: the CTM could not read its protocol version ({e})"
                ));
                None
            }
        };
        let verifier = if protocol_version == Some(departing) {
            read_chain_verifier(provider, result, &bridgehub, chain_id).await
        } else {
            None
        };
        chains.push(ChainVersion {
            chain_id,
            protocol_version,
            verifier,
        });
    }
    chains
}

/// The verifier chain `chain_id` runs, through its diamond.
async fn read_chain_verifier<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    bridgehub: &BridgehubView::BridgehubViewInstance<&P>,
    chain_id: U256,
) -> Option<Address> {
    let read = async {
        let diamond = bridgehub.getZKChain(chain_id).call().await?;
        ZkChainGettersView::new(diamond, provider)
            .getVerifier()
            .call()
            .await
    };
    match read.await {
        Ok(verifier) => Some(verifier),
        Err(e) => {
            result.report_warn(&format!(
                "chain {chain_id}: the verifier it runs could not be read ({e}), so it offers the \
                 release no verifier to carry over"
            ));
            None
        }
    }
}

/// Reports every chain on the CTM below the edge's departing version. A warning, not an error:
/// such a chain still upgrades along the pre-registry edges, whose upgrade engines read the CTM's
/// legacy `protocolVersionVerifier` getter — governance needs to know who still depends on it.
fn judge_lagging_chains(result: &mut VerificationResult, departing: U256, chains: &[ChainVersion]) {
    let mut lagging = 0usize;
    let mut unknown = 0usize;
    for chain in chains {
        match chain.protocol_version {
            Some(version) if version < departing => {
                lagging += 1;
                result.report_warn(&format!(
                    "chain {} is at {}, below the departing {}: it reaches {} only along the \
                     pre-registry edges, through the CTM's legacy `protocolVersionVerifier` getter",
                    chain.chain_id,
                    format_semver(version),
                    format_semver(departing),
                    format_semver(departing)
                ));
            }
            Some(_) => {}
            None => unknown += 1,
        }
    }
    if lagging == 0 && unknown == 0 {
        result.report_ok(&format!(
            "none of the {} chain(s) on the CTM is below the departing version {}",
            chains.len(),
            format_semver(departing)
        ));
        return;
    }
    result.print_info(&format!(
        "  {lagging} of {} chain(s) on the CTM are below the departing version {}",
        chains.len(),
        format_semver(departing)
    ));
    if unknown > 0 {
        result.print_info(&format!(
            "  {unknown} chain(s) could not be read and may lag too"
        ));
    }
}

/// The prerequisite's verdict, for the row check that follows it.
struct NotifierHandover {
    /// The notifier proxy sits under the manifest's CTM-domain `ProxyAdmin`, so its row can be
    /// read through that admin like every other.
    under_ctm_proxy_admin: bool,
}

/// What the chain says about the ServerNotifier the manifest's mandatory row names. A getter that
/// could not be read is `None` (and already reported).
struct NotifierFacts {
    notifier: Address,
    ctm_notifier: Option<Address>,
    notifier_ctm: Option<Address>,
    proxy_admin: Address,
    owner: Option<Address>,
    pending_owner: Option<Address>,
}

/// The one-time ServerNotifier handover `RegistryBootstrapMigration.validate()` requires complete
/// before `migrate()` can run (see "ServerNotifier: a one-time handover, then an ordinary
/// CTM-domain proxy" in `docs/upgrade-operations.md`), read live.
async fn verify_notifier_handover<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    manifest: &views::BootstrapManifest,
    bundle: &[GovernanceCall],
) -> anyhow::Result<NotifierHandover> {
    let Some(row) = manifest
        .ctmProxyUpgrades
        .get(CTM_CONTRACT_SERVER_NOTIFIER_SLOT)
        .filter(|row| !row.implNew.is_zero())
    else {
        result.report_error(&format!(
            "the manifest carries no ServerNotifier row (CTMContract slot \
             {CTM_CONTRACT_SERVER_NOTIFIER_SLOT}): the reviewed migration refuses construction \
             without it (`BootstrapServerNotifierRowMissing`), so this migration does not come \
             from the reviewed code, and the handover cannot be checked"
        ));
        return Ok(NotifierHandover {
            under_ctm_proxy_admin: false,
        });
    };
    let notifier = row.proxy;
    let notifier_view = ServerNotifierView::new(notifier, provider);
    // A transparent proxy answers `admin()` only to its admin, so the slot itself is read.
    let admin_word = provider
        .get_storage_at(notifier, EIP1967_PROXY_ADMIN_SLOT.into())
        .await?;
    let facts = NotifierFacts {
        notifier,
        ctm_notifier: tolerate(
            CtmView::new(manifest.ctm, provider)
                .serverNotifierAddress()
                .call()
                .await,
            result,
            "the CTM's serverNotifierAddress()",
        ),
        notifier_ctm: tolerate(
            notifier_view.chainTypeManager().call().await,
            result,
            "the ServerNotifier's chainTypeManager()",
        ),
        proxy_admin: Address::from_word(admin_word.into()),
        owner: tolerate(
            notifier_view.owner().call().await,
            result,
            "the ServerNotifier's owner",
        ),
        pending_owner: tolerate(
            notifier_view.pendingOwner().call().await,
            result,
            "the ServerNotifier's pending owner",
        ),
    };
    Ok(judge_notifier_handover(result, &facts, manifest, bundle))
}

/// The handover verdict over the live facts: anything short of a completed handover — or a
/// nomination the bundle's derived first call accepts — is an ERROR, because `migrate()` refuses
/// it.
fn judge_notifier_handover(
    result: &mut VerificationResult,
    facts: &NotifierFacts,
    manifest: &views::BootstrapManifest,
    bundle: &[GovernanceCall],
) -> NotifierHandover {
    const MISSING: &str = "the ChainAdmin half of the ServerNotifier handover is missing: the \
                           prepare's `[ctm_admin_calls] server_notifier_handover` calls must be \
                           executed by their live owners before the bundle, or its `migrate()` \
                           refuses";
    let notifier = facts.notifier;
    let executor = manifest.ctmExecutor;

    match facts.ctm_notifier {
        Some(bound) if bound == notifier => result.report_ok(&format!(
            "the manifest's ServerNotifier row names the CTM's notifier {notifier}"
        )),
        Some(bound) => result.report_error(&format!(
            "the manifest's ServerNotifier row names {notifier} but the CTM's notifier is {bound}: \
             `migrate()` refuses (`BootstrapServerNotifierNotBound`)"
        )),
        None => {}
    }
    match facts.notifier_ctm {
        Some(ctm) if ctm == manifest.ctm => {
            result.report_ok("the ServerNotifier serves the CTM the manifest names")
        }
        Some(ctm) => result.report_error(&format!(
            "the ServerNotifier serves CTM {ctm}, not the manifest's {}: `migrate()` refuses \
             (`BootstrapServerNotifierNotBound`)",
            manifest.ctm
        )),
        None => {}
    }

    let under_ctm_proxy_admin = facts.proxy_admin == manifest.ctmProxyAdmin;
    if under_ctm_proxy_admin {
        result.report_ok(&format!(
            "the ServerNotifier proxy is administered by the CTM-domain ProxyAdmin {}",
            manifest.ctmProxyAdmin
        ));
    } else {
        result.report_error(&format!(
            "the ServerNotifier proxy is administered by {} (EIP-1967 admin slot), not by the \
             CTM-domain ProxyAdmin {} — {MISSING}",
            facts.proxy_admin, manifest.ctmProxyAdmin
        ));
    }

    let acceptance = notifier_acceptance(executor, notifier);
    let bundle_accepts = bundle.iter().any(|call| {
        call.target == acceptance.target
            && call.value == acceptance.value
            && call.data == acceptance.data
    });
    match (facts.owner, facts.pending_owner) {
        (Some(owner), pending) if owner == executor => {
            match pending {
                Some(pending) if pending.is_zero() => result.report_ok(&format!(
                    "the ServerNotifier is owned by the CTM executor {executor} with no nomination \
                     outstanding: the handover is complete"
                )),
                Some(pending) => result.report_error(&format!(
                    "the ServerNotifier is owned by the CTM executor but has a pending owner \
                     {pending}: `migrate()` refuses an outstanding nomination"
                )),
                None => {}
            }
            if bundle_accepts {
                result.report_error(
                    "the bundle accepts the ServerNotifier ownership, which the CTM executor \
                     already holds: `acceptOwnership` reverts for a caller that is not the \
                     pending owner, so the bundle was prepared against an earlier state and would \
                     fail",
                );
            }
        }
        (Some(owner), Some(pending)) if pending == executor => {
            result.report_ok(&format!(
                "the ServerNotifier's owner {owner} has nominated the CTM executor {executor}: the \
                 ChainAdmin half of the ownership handover is done"
            ));
            if bundle_accepts {
                result.report_ok(
                    "the bundle carries governance's acceptance of that nomination (`forward` on \
                     the CTM executor)",
                );
            } else {
                result.report_error(
                    "the bundle does not carry governance's acceptance of the ServerNotifier \
                     nomination (`forward([acceptOwnership()])` on the CTM executor): the \
                     nomination would stay unaccepted, and its `migrate()` refuses",
                );
            }
        }
        (Some(owner), Some(pending)) => result.report_error(&format!(
            "the ServerNotifier is owned by {owner} with pending owner {pending}, neither of \
             which is the CTM executor {executor} — {MISSING}"
        )),
        _ => {}
    }

    NotifierHandover {
        under_ctm_proxy_admin,
    }
}

/// The bundle call through which governance accepts the ServerNotifier ownership the ChainAdmin
/// nominated the CTM executor for: `ctmExecutor.forward([notifier.acceptOwnership()])`.
fn notifier_acceptance(ctm_executor: Address, notifier: Address) -> GovernanceCall {
    let accept = BootstrapCall {
        target: notifier,
        value: U256::ZERO,
        data: ServerNotifierView::acceptOwnershipCall {}
            .abi_encode()
            .into(),
    };
    GovernanceCall {
        target: ctm_executor,
        value: U256::ZERO,
        data: CTMUpgradeExecutorView::forwardCall {
            _calls: vec![accept],
        }
        .abi_encode(),
    }
}

/// The bootstrap sequence over this edge, DERIVED rather than read from the package: the address
/// the deterministic factory gives the reviewed creation code over the migration (recovered from
/// the bundle's `migrate()`) and the package's core transition, under a reviewed salt. Code there
/// is the reviewed constructor having run on exactly those arguments, so the package has no say in
/// which oracle its bundle is compared against.
///
/// Returns the first derived address that holds code, and nothing when none does.
async fn locate_sequence<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    package: &BootstrapPackage,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Option<Address>> {
    let label = "the bootstrap sequence over this edge";
    let Some(core_transition) = package.core_transition else {
        result.report_error(&format!(
            "{label}: the package names no core transition, but the sequence is constructed over \
             the edge's core transition, so its address cannot be derived and the list it derives \
             cannot be read"
        ));
        return Ok(None);
    };
    let creation_code = match build.get("RegistryBootstrapSequence") {
        Ok(code) => code,
        Err(why) => {
            result.report_error(&format!("{label}: its address cannot be derived — {why}"));
            return Ok(None);
        }
    };
    if salts.is_empty() {
        result.report_error(&format!(
            "{label}: no CREATE2 salt is available, so its address cannot be derived. Pass \
             --create2-salt with the reviewed salts from the upgrade env"
        ));
        return Ok(None);
    }
    let args = constructor_args::registry_bootstrap_sequence(package.migration, core_transition);
    let mut derived = Vec::with_capacity(salts.len());
    for salt in salts {
        let address = canonical_create2_address(*salt, creation_code.creation_code(), &args);
        if !provider.get_code_at(address).await?.is_empty() {
            result.report_ok(&format!(
                "{label} is deployed at {address}: the reviewed RegistryBootstrapSequence built \
                 over migration {} and core transition {core_transition} (CREATE2 salt {salt})",
                package.migration
            ));
            reviewed.insert(address, label.to_string());
            return Ok(Some(address));
        }
        derived.push(format!("salt {salt} -> {address}"));
    }
    result.report_error(&format!(
        "{label} is not deployed: the reviewed RegistryBootstrapSequence over migration {} and \
         core transition {core_transition} lands at {}, and none of them holds code — the list it \
         derives cannot be read, so the bundle cannot be held against anything",
        package.migration,
        derived.join("; ")
    ));
    Ok(None)
}

/// A storage binding the bundle sets through `setter`: unset, or already the manifest's.
fn expect_bound_or_unset(
    result: &mut VerificationResult,
    label: &str,
    bound: Option<Address>,
    expected: Address,
    setter: &str,
) {
    match bound {
        Some(bound) if bound == expected => {
            result.report_ok(&format!("{label} is already the manifest's {expected}"))
        }
        Some(bound) if bound.is_zero() => result.report_ok(&format!(
            "{label} is unset: the bundle sets it to {expected} ({setter}, in the derived \
             sequence)"
        )),
        Some(bound) => result.report_error(&format!(
            "{label} is {bound}, not the manifest's {expected}: the objects this edge binds are \
             fresh, so the binding means one of them is already in use elsewhere — the bundle \
             would re-point it ({setter}) or revert"
        )),
        None => {}
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
/// ecosystem `ProxyAdmin` derived from them.
///
/// The derived sequence is the complete list of what the edge needs from these; a call to any
/// of them outside that list is authority the review never saw, so [`verify_bundle`] refuses it
/// whether the package declares it or not.
fn edge_authorities(
    manifest: &views::BootstrapManifest,
    bindings: &LifecycleBindings,
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
    note(
        Some(manifest.currentRelease),
        "the release the manifest names",
    );
    note(
        Some(manifest.coreExecutor),
        "the core executor the manifest names",
    );
    note(
        bindings.core_proxy_admin,
        "the ecosystem ProxyAdmin the core executor names",
    );
    note(core_transition, "the core transition");
    note(sequence, "the bootstrap sequence over this edge");
    authorities
}

/// Compares the bundle against the list `RegistryBootstrapSequence.actions()` derives.
///
/// # This comparison is TRANSITIONAL SCAFFOLDING, and must not be generalised
///
/// It exists for one reason: a bootstrap edge has no executor to invoke, so GOVERNANCE EXECUTES
/// THE LIST rather than invoking the sequence to execute it. Reviewing the sequence contract
/// therefore does not establish that the calls governance will sign are the calls it derives —
/// only comparing them does.
///
/// Every LATER upgrade is a recurring operation, where governance signs
/// `coordinator.execute(operation)` and the executors derive everything else on chain. That path
/// needs no list comparison and must not grow one: see
/// [`operation::verify_execute_call`](super::operation). Do not build new machinery on top of
/// this function — when the bootstrap edge is behind us, it goes.
///
/// `sequence` is the address [`locate_sequence`] derived from the reviewed migration and core
/// transition; with none, no list is consulted.
async fn verify_derived_sequence<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    package: &BootstrapPackage,
    sequence: Option<Address>,
    authorities: &BTreeMap<Address, String>,
) {
    let Some(sequence_addr) = sequence else {
        result.report_error(
            "the bootstrap sequence over this edge is not established, so the calls it derives \
             are not consulted and the submitted bundle cannot be held against anything: the \
             bundle is unreviewed",
        );
        return;
    };
    let derived = match views::RegistryBootstrapSequenceView::new(sequence_addr, provider)
        .actions()
        .call()
        .await
    {
        Ok(actions) => actions,
        Err(e) => {
            result.report_error(&format!(
                "the sequence at {sequence_addr} does not answer `actions()` ({e}): the submitted \
                 bundle cannot be held against the list it derives"
            ));
            return;
        }
    };
    verify_bundle(
        &package.calls,
        &derived,
        &package.external_actions,
        authorities,
        package.migration,
        result,
    );
}

/// The bundle against the list the (construction-verified) sequence derives.
///
/// The derived calls must appear as one contiguous run, in order and one-for-one, that ENDS the
/// bundle: the edge's own steps depend on each other (the handovers before `migrate()`), and its
/// last call is the completion check `validateApplied()` on the migration, so nothing may follow
/// it. Ahead of that run the merge may prepend its extras — the governance-set wiring, the CTM
/// `acceptOwnership()` normalization — and every such call is held to the rule the recurring path
/// enforces: it must be a declared governance external action, or it is an ERROR. One rule is
/// stricter here. The derived run is the COMPLETE list of what the edge needs from its
/// authorities (the CTM, both ProxyAdmins, the executors, the objects), so a call to any of them
/// outside the run is an ERROR whether declared or not: a `transferOwnership` nomination, a
/// `setCoordinator`, a `forward` added beside the legitimate calls is exactly how a bundle would
/// carry authority governance never reviewed, and `validateApplied()` on chain refuses a pending
/// nomination for the same reason.
fn verify_bundle(
    submitted: &[GovernanceCall],
    derived: &[views::BootstrapAction],
    declared: &[ExternalAction],
    authorities: &BTreeMap<Address, String>,
    migration: Address,
    result: &mut VerificationResult,
) {
    let completion = RegistryBootstrapMigrationView::validateAppliedCall {}.abi_encode();
    match derived.last() {
        Some(last) if last.call.target == migration && last.call.data[..] == completion[..] => {
            result.report_ok(&format!(
                "the derived sequence ends with `validateApplied()` on the migration {migration}: \
                 a failing completion check reverts the whole bootstrap bundle"
            ))
        }
        Some(_) => result.report_error(&format!(
            "the derived sequence does not end with `validateApplied()` on the migration \
             {migration}, which every bootstrap bundle does: the sequence is not describing this \
             edge"
        )),
        None => result.report_error(
            "the sequence derives no calls, which no bootstrap edge does: the sequence is not \
             describing this edge",
        ),
    }

    let run = if derived.is_empty() {
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
                "the bundle carries the {} call(s) the sequence derives, in order (at offset {at} \
                 of {} submitted)",
                derived.len(),
                submitted.len()
            ));
            for action in derived {
                result.print_info(&format!(
                    "    · {} — {} (authority: {})",
                    action.label, action.call.target, action.authority
                ));
            }
            let trailing = submitted.len() - (at + derived.len());
            if trailing > 0 {
                result.report_error(&format!(
                    "{trailing} call(s) follow the derived run: the run must end the bundle, \
                     whose last call is the completion check"
                ));
            }
        }
        None if !derived.is_empty() => result.report_error(&format!(
            "the bundle's {} submitted call(s) do not contain the {} call(s) the sequence \
             derives, in order: governance would sign a bundle the reviewed edge does not describe",
            submitted.len(),
            derived.len()
        )),
        None => {}
    }

    let in_run = |index: usize| run.is_some_and(|at| (at..at + derived.len()).contains(&index));
    let mut extras = 0usize;
    for (index, call) in submitted.iter().enumerate() {
        if in_run(index) {
            continue;
        }
        let selector = alloy::hex::encode(call.data.get(..4).unwrap_or_default());
        if let Some(what) = authorities.get(&call.target) {
            extras += 1;
            result.report_error(&format!(
                "the bundle calls {what} ({}) with selector 0x{selector} outside the derived \
                 sequence: the edge's authorities take exactly the derived calls, so an extra \
                 one — a `transferOwnership` nomination, a `setCoordinator`, a `forward` — is \
                 authority the review never saw, whether or not the package declares it",
                call.target
            ));
            continue;
        }
        match declared
            .iter()
            .find(|action| action.phase == GOVERNANCE_PHASE && action.is_call(call))
        {
            Some(action) => result.print_info(&format!(
                "  bundle -> declared external action `{}` on {} (selector 0x{selector})",
                action.label, call.target
            )),
            None => {
                extras += 1;
                result.report_error(&format!(
                    "the bundle calls {} (selector 0x{selector}), which is neither derived by the \
                     sequence nor a declared governance external action: the bundle carries an \
                     instruction no part of this review accounts for",
                    call.target
                ));
            }
        }
    }
    if extras == 0 && run.is_some() {
        result.report_ok(
            "every submitted call is derived by the sequence or a declared external action to a \
             target outside the edge's authorities",
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::registry::views::ProxyUpgradeRow;
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
            ctmProxyUpgrades: Vec::new(),
            currentRelease: Address::repeat_byte(0x33),
            oldProtocolVersionDeadline: U256::from(3),
            upgradeEngine: Address::repeat_byte(0x44),
            l2Plan: views::AuthoredL2Plan {
                delegateBytecodeInfo: Default::default(),
                extraBytecodeInfos: Vec::new(),
                delegateComposer: Address::ZERO,
            },
            upgradeTimestamp: U256::from(0),
            ctmExecutor: Address::repeat_byte(0x55),
            coreExecutor: Address::repeat_byte(0x67),
            governance: Address::repeat_byte(0x66),
            coordinator: Address::repeat_byte(0x77),
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

    // ───────────────────────── the bundle rule ─────────────────────────
    //
    // A bundle shaped like the one `RegistryBootstrapSequence.actions()` derives, over synthetic
    // addresses, so the rule can be driven without a chain: the derived run, the authorities it
    // touches, and what may or may not sit beside it.

    const CTM: Address = Address::repeat_byte(0x01);
    const CTM_ADMIN: Address = Address::repeat_byte(0x02);
    const ECO_ADMIN: Address = Address::repeat_byte(0x03);
    const CORE_EXECUTOR: Address = Address::repeat_byte(0x04);
    const MIGRATION: Address = Address::repeat_byte(0x05);
    const PUH: Address = Address::repeat_byte(0x07);
    const COORDINATOR: Address = Address::repeat_byte(0x0C);
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

    fn completion_check() -> Vec<u8> {
        views::RegistryBootstrapMigrationView::validateAppliedCall {}.abi_encode()
    }

    fn derived_bundle() -> Vec<views::BootstrapAction> {
        vec![
            action(
                "bind the core executor to the coordinator",
                CORE_EXECUTOR,
                vec![0x55, 0x66, 0x77, 0x88],
            ),
            action(
                "bind the coordinator to the CTM executor",
                COORDINATOR,
                vec![0x99, 0xaa, 0xbb, 0xcc],
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
            action("check the edge completed", MIGRATION, completion_check()),
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
                ExternalAction::governance(
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
            (COORDINATOR, "the coordinator"),
            (MIGRATION, "the bootstrap migration"),
        ]
        .into_iter()
        .map(|(a, s)| (a, s.to_string()))
        .collect()
    }

    fn run_with(
        submitted: &[GovernanceCall],
        derived: &[views::BootstrapAction],
        declared: &[ExternalAction],
    ) -> VerificationResult {
        let mut result = VerificationResult::default();
        verify_bundle(
            submitted,
            derived,
            declared,
            &authorities(),
            MIGRATION,
            &mut result,
        );
        result
    }

    fn run(submitted: &[GovernanceCall], declared: &[ExternalAction]) -> VerificationResult {
        run_with(submitted, &derived_bundle(), declared)
    }

    #[test]
    fn the_derived_run_alone_passes() {
        let derived = derived_bundle();
        let result = run(&submitted_from(&derived), &declared_from(&derived));
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
    }

    /// THE finding: `coreExecutor.transferOwnership(attacker)` appended after the legitimate
    /// run. The address is known (it takes two derived calls earlier in the run), the selector
    /// is one the run itself uses, and the nominee would accept after the bundle and own the
    /// ecosystem domain. It also sits after the completion check, which must end the bundle.
    #[test]
    fn a_nomination_appended_after_the_run_fails() {
        let derived = derived_bundle();
        let mut submitted = submitted_from(&derived);
        submitted.push(call(CORE_EXECUTOR, transfer_ownership(ATTACKER)));
        let result = run(&submitted, &declared_from(&derived));
        assert_eq!(result.errors, 2);
        assert!(result.ensure_success().is_err());
    }

    /// Declaring the nomination does not launder it: an authority takes exactly the derived
    /// calls, and the package author controls the declarations.
    #[test]
    fn a_declared_nomination_on_an_authority_still_fails() {
        let derived = derived_bundle();
        let extra = call(CORE_EXECUTOR, transfer_ownership(ATTACKER));
        let mut submitted = vec![extra.clone()];
        submitted.extend(submitted_from(&derived));
        let mut declared = declared_from(&derived);
        declared.push(ExternalAction::governance(
            "bind the core executor",
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
        let derived = derived_bundle();
        for (target, data) in [
            (CTM, transfer_ownership(ATTACKER)),
            (CTM_ADMIN, vec![0xde, 0xad, 0xbe, 0xef]),
            (MIGRATION, vec![0x01, 0x02, 0x03, 0x04]),
            (COORDINATOR, vec![0xaa, 0xbb, 0xcc, 0xdd]),
        ] {
            let mut submitted = submitted_from(&derived);
            submitted.insert(0, call(target, data));
            let result = run(&submitted, &declared_from(&derived));
            assert_eq!(result.errors, 1, "an extra call to {target} must fail");
        }
    }

    /// What the merge legitimately prepends — the governance-set wiring on the PUH — is a
    /// declared action to a target outside the edge's authorities, and rides along.
    #[test]
    fn a_declared_prefix_outside_the_authorities_rides_along() {
        let derived = derived_bundle();
        let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
        let mut submitted = vec![wiring.clone()];
        submitted.extend(submitted_from(&derived));
        let mut declared = declared_from(&derived);
        declared.push(ExternalAction::governance(
            "wire the new governance set",
            "governance",
            &wiring,
        ));
        let result = run(&submitted, &declared);
        assert_eq!(result.errors, 0);
    }

    /// The same prefix UNDECLARED is the recurring path's rule, applied here too.
    #[test]
    fn an_undeclared_prefix_outside_the_authorities_fails() {
        let derived = derived_bundle();
        let mut submitted = vec![call(PUH, vec![0x99, 0x88, 0x77, 0x66])];
        submitted.extend(submitted_from(&derived));
        let result = run(&submitted, &declared_from(&derived));
        assert_eq!(result.errors, 1);
    }

    /// Nothing may follow the completion check, not even a declared call outside the
    /// authorities: the check is the bundle's last word on whether the edge completed.
    #[test]
    fn a_declared_call_after_the_completion_check_fails() {
        let derived = derived_bundle();
        let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
        let mut submitted = submitted_from(&derived);
        submitted.push(wiring.clone());
        let mut declared = declared_from(&derived);
        declared.push(ExternalAction::governance("wiring", "governance", &wiring));
        let result = run(&submitted, &declared);
        assert_eq!(result.errors, 1);
    }

    /// An `admin` declaration rides no governance bundle, so it does not account for a call in
    /// one.
    #[test]
    fn an_admin_declaration_does_not_count() {
        let derived = derived_bundle();
        let wiring = call(PUH, vec![0x99, 0x88, 0x77, 0x66]);
        let mut submitted = vec![wiring.clone()];
        submitted.extend(submitted_from(&derived));
        let mut declared = declared_from(&derived);
        let mut admin = ExternalAction::governance("wiring", "governance", &wiring);
        admin.phase = "admin".to_string();
        declared.push(admin);
        let result = run(&submitted, &declared);
        assert_eq!(result.errors, 1);
    }

    /// The run must be contiguous and in order: the handovers before `migrate()`.
    #[test]
    fn a_reordered_run_fails() {
        let derived = derived_bundle();
        let mut submitted = submitted_from(&derived);
        submitted.swap(5, 6);
        let result = run(&submitted, &declared_from(&derived));
        assert!(result.errors >= 1);
        assert!(result.ensure_success().is_err());
    }

    /// A derived call missing from the bundle is not a run at all — the completion check
    /// included.
    #[test]
    fn a_dropped_derived_call_fails() {
        let derived = derived_bundle();
        for dropped in [2, derived.len() - 1] {
            let mut submitted = submitted_from(&derived);
            submitted.remove(dropped);
            let result = run(&submitted, &declared_from(&derived));
            assert!(result.errors >= 1, "dropping call {dropped} must fail");
        }
    }

    /// A sequence whose list does not end in `validateApplied()` on the migration is not the
    /// reviewed bootstrap sequence describing this edge, even when the bundle matches it.
    #[test]
    fn a_sequence_not_ending_in_the_completion_check_fails() {
        let mut derived = derived_bundle();
        derived.pop();
        let result = run_with(
            &submitted_from(&derived),
            &derived,
            &declared_from(&derived),
        );
        assert_eq!(result.errors, 1);

        let mut elsewhere = derived_bundle();
        elsewhere.last_mut().unwrap().call.target = ATTACKER;
        let result = run_with(
            &submitted_from(&elsewhere),
            &elsewhere,
            &declared_from(&elsewhere),
        );
        assert_eq!(result.errors, 1);
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

    fn package() -> BootstrapPackage {
        BootstrapPackage {
            core_transition: Some(CORE_TRANSITION),
            release: Address::repeat_byte(0x09),
            migration: MIGRATION,
            reported_migration: None,
            reported_coordinator: None,
            reported_ctm_executor: None,
            reported_ctm: None,
            reported_ctm_proxy_admin: None,
            ctm_key: "zksync_os".to_string(),
            calls: Vec::new(),
            external_actions: Vec::new(),
            create2_salts: Vec::new(),
            lifecycle: Default::default(),
            force_deployments_data: None,
            executor_records: Default::default(),
        }
    }

    fn genuine_sequence(salt: B256) -> Address {
        canonical_create2_address(
            salt,
            &sequence_code(),
            &constructor_args::registry_bootstrap_sequence(MIGRATION, CORE_TRANSITION),
        )
    }

    async fn locate(
        asserter: &Asserter,
        package: &BootstrapPackage,
        salts: &[B256],
    ) -> (
        Option<Address>,
        VerificationResult,
        BTreeMap<Address, String>,
    ) {
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        let sequence = locate_sequence(
            &provider,
            &build(),
            &mut result,
            package,
            salts,
            &mut reviewed,
        )
        .await
        .unwrap();
        (sequence, result, reviewed)
    }

    /// The oracle the bundle is compared against is DERIVED from the reviewed creation code over
    /// the migration and core transition, never read from the package — so it is established by
    /// construction, and only then is its list read and the bundle held against it.
    #[tokio::test]
    async fn the_derived_sequence_is_established_and_then_consulted() {
        let genuine = genuine_sequence(SALT);
        let mut package = package();
        let derived = derived_bundle();
        package.calls = submitted_from(&derived);
        package.external_actions = declared_from(&derived);

        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(&[0x60, 0x00])); // code at the derived address
        asserter.push_success(&Bytes::from(derived.abi_encode()));
        let (sequence, mut result, reviewed) = locate(&asserter, &package, &[SALT]).await;
        assert_eq!(sequence, Some(genuine));
        assert_eq!(reviewed.len(), 1);

        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut authorities = authorities();
        authorities.insert(genuine, "the bootstrap sequence".to_string());
        verify_derived_sequence(&provider, &mut result, &package, sequence, &authorities).await;
        assert!(asserter.read_q().is_empty(), "the list was read");
        assert_eq!(
            result.errors, 0,
            "a bundle that IS the derived sequence passes"
        );
    }

    /// The sequence is found under whichever reviewed salt built it.
    #[tokio::test]
    async fn the_sequence_is_found_under_the_salt_that_built_it() {
        let other_salt = B256::repeat_byte(0x11);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::new()); // nothing under the first salt
        asserter.push_success(&Bytes::from_static(&[0x60, 0x00]));
        let (sequence, result, _) = locate(&asserter, &package(), &[other_salt, SALT]).await;
        assert_eq!(sequence, Some(genuine_sequence(SALT)));
        assert_eq!(result.errors, 0);
    }

    /// Nothing deployed at the derived address: an error, and no list is ever read — the queued
    /// list answer stays unconsumed.
    #[tokio::test]
    async fn an_undeployed_sequence_is_never_consulted() {
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::new());
        asserter.push_success(&Bytes::from(
            Vec::<views::BootstrapAction>::new().abi_encode(),
        ));
        let package = package();
        let (sequence, mut result, reviewed) = locate(&asserter, &package, &[SALT]).await;
        assert_eq!(sequence, None);
        assert_eq!(result.errors, 1);
        assert!(reviewed.is_empty());

        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        verify_derived_sequence(&provider, &mut result, &package, sequence, &BTreeMap::new()).await;
        assert_eq!(asserter.read_q().len(), 1, "no list may be read");
        assert_eq!(result.errors, 2);
    }

    /// A bootstrap package without a core transition has nothing to derive the sequence over:
    /// an error, not a sequence taken on trust.
    #[tokio::test]
    async fn a_sequence_without_a_core_transition_is_unverifiable() {
        let mut package = package();
        package.core_transition = None;
        let (sequence, result, _) = locate(&Asserter::new(), &package, &[SALT]).await;
        assert_eq!(sequence, None);
        assert_eq!(result.errors, 1);
    }

    // ───────────────────────── the ServerNotifier handover ─────────────────────────
    //
    // The facts as the chain reports them at review time, judged against a manifest whose
    // mandatory notifier row names NOTIFIER. Every state short of "complete", or "nominated and
    // accepted by the bundle's derived first call", must be an error: `migrate()` refuses it.

    const NOTIFIER: Address = Address::repeat_byte(0x2A);
    const CTM_EXECUTOR: Address = Address::repeat_byte(0x2B);
    const CHAIN_ADMIN: Address = Address::repeat_byte(0x2C);
    const DEPLOYER: Address = Address::repeat_byte(0x2D);
    const OLD_NOTIFIER_ADMIN: Address = Address::repeat_byte(0x2E);

    fn notifier_row() -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy: NOTIFIER,
            expectedOldImpl: Address::repeat_byte(0x3A),
            implNew: Address::repeat_byte(0x3B),
            callInitializeUpgrade: false,
        }
    }

    fn inert_row() -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy: Address::ZERO,
            expectedOldImpl: Address::ZERO,
            implNew: Address::ZERO,
            callInitializeUpgrade: false,
        }
    }

    fn manifest_with(notifier: ProxyUpgradeRow) -> views::BootstrapManifest {
        let mut proxy_upgrades = vec![inert_row(); CTM_CONTRACT_SERVER_NOTIFIER_SLOT + 1];
        proxy_upgrades[CTM_CONTRACT_SERVER_NOTIFIER_SLOT] = notifier;
        views::BootstrapManifest {
            ctm: CTM,
            expectedProtocolVersion: U256::from(1),
            ctmProxyAdmin: CTM_ADMIN,
            ctmProxyUpgrades: proxy_upgrades,
            currentRelease: Address::repeat_byte(0x33),
            oldProtocolVersionDeadline: U256::ZERO,
            upgradeEngine: Address::repeat_byte(0x44),
            l2Plan: views::AuthoredL2Plan {
                delegateBytecodeInfo: Default::default(),
                extraBytecodeInfos: Vec::new(),
                delegateComposer: Address::ZERO,
            },
            upgradeTimestamp: U256::ZERO,
            ctmExecutor: CTM_EXECUTOR,
            coreExecutor: Address::repeat_byte(0x67),
            governance: Address::repeat_byte(0x66),
            coordinator: Address::repeat_byte(0x77),
        }
    }

    /// A notifier bound to the manifest's CTM, with the given authority state.
    fn notifier_facts(
        owner: Address,
        pending_owner: Address,
        proxy_admin: Address,
    ) -> NotifierFacts {
        NotifierFacts {
            notifier: NOTIFIER,
            ctm_notifier: Some(NOTIFIER),
            notifier_ctm: Some(CTM),
            proxy_admin,
            owner: Some(owner),
            pending_owner: Some(pending_owner),
        }
    }

    fn judge(facts: &NotifierFacts, bundle: &[GovernanceCall]) -> (VerificationResult, bool) {
        let mut result = VerificationResult::default();
        let verdict =
            judge_notifier_handover(&mut result, facts, &manifest_with(notifier_row()), bundle);
        (result, verdict.under_ctm_proxy_admin)
    }

    fn accepting_bundle() -> Vec<GovernanceCall> {
        vec![notifier_acceptance(CTM_EXECUTOR, NOTIFIER)]
    }

    #[test]
    fn a_completed_handover_passes() {
        let facts = notifier_facts(CTM_EXECUTOR, Address::ZERO, CTM_ADMIN);
        let (result, readable) = judge(&facts, &[]);
        assert_eq!(result.errors, 0);
        assert!(readable);
    }

    /// The ChainAdmin moved the proxy and nominated the executor; governance's acceptance is the
    /// bundle's first derived call, and the bundle carries it.
    #[test]
    fn a_nomination_the_bundle_accepts_passes() {
        let facts = notifier_facts(CHAIN_ADMIN, CTM_EXECUTOR, CTM_ADMIN);
        let (result, readable) = judge(&facts, &accepting_bundle());
        assert_eq!(result.errors, 0);
        assert!(readable);
    }

    #[test]
    fn a_nomination_the_bundle_does_not_accept_fails() {
        let facts = notifier_facts(CHAIN_ADMIN, CTM_EXECUTOR, CTM_ADMIN);
        let (result, _) = judge(&facts, &[]);
        assert_eq!(result.errors, 1);
    }

    /// The frozen v34 fixture before the ChainAdmin acted: the deployer still owns the notifier
    /// with the ChainAdmin nominated (never accepted), and the proxy sits under its own
    /// ChainAdmin-owned ProxyAdmin. Both halves are reported, and the notifier row is marked
    /// unreadable through the CTM-domain admin.
    #[test]
    fn the_untouched_v34_notifier_is_the_missing_chain_admin_half() {
        let facts = notifier_facts(DEPLOYER, CHAIN_ADMIN, OLD_NOTIFIER_ADMIN);
        let (result, readable) = judge(&facts, &accepting_bundle());
        assert_eq!(result.errors, 2);
        assert!(!readable);
        assert!(result.ensure_success().is_err());
    }

    /// The bundle was prepared while the nomination was pending, and governance accepted
    /// outside it since: the bundle would revert on its own first derived call.
    #[test]
    fn an_acceptance_of_an_already_accepted_ownership_fails() {
        let facts = notifier_facts(CTM_EXECUTOR, Address::ZERO, CTM_ADMIN);
        let (result, _) = judge(&facts, &accepting_bundle());
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_nomination_outstanding_after_the_acceptance_fails() {
        let facts = notifier_facts(CTM_EXECUTOR, ATTACKER, CTM_ADMIN);
        let (result, _) = judge(&facts, &[]);
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_notifier_bound_to_another_ctm_fails_both_ways() {
        let mut facts = notifier_facts(CTM_EXECUTOR, Address::ZERO, CTM_ADMIN);
        facts.ctm_notifier = Some(Address::repeat_byte(0x4A));
        facts.notifier_ctm = Some(Address::repeat_byte(0x4B));
        let (result, _) = judge(&facts, &[]);
        assert_eq!(result.errors, 2);
    }

    /// The acceptance is `RegistryBootstrapSequence.actions()`' first call while the handover is
    /// pending: `forward(Call[])` on the executor wrapping `acceptOwnership()` on the notifier.
    #[test]
    fn the_acceptance_forwards_accept_ownership_to_the_notifier() {
        let call = notifier_acceptance(CTM_EXECUTOR, NOTIFIER);
        assert_eq!(call.target, CTM_EXECUTOR);
        assert_eq!(
            &call.data[..4],
            &alloy::primitives::keccak256(b"forward((address,uint256,bytes)[])")[..4]
        );
        let decoded = CTMUpgradeExecutorView::forwardCall::abi_decode(&call.data).unwrap();
        assert_eq!(decoded._calls.len(), 1);
        assert_eq!(decoded._calls[0].target, NOTIFIER);
        assert_eq!(
            &decoded._calls[0].data[..],
            &alloy::primitives::keccak256(b"acceptOwnership()")[..4]
        );
    }

    #[tokio::test]
    async fn a_manifest_without_the_notifier_row_is_an_error() {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let verdict =
            verify_notifier_handover(&provider, &mut result, &manifest_with(inert_row()), &[])
                .await
                .unwrap();
        assert_eq!(result.errors, 1);
        assert!(!verdict.under_ctm_proxy_admin);
    }

    /// The live read path, in the order it queries: the proxy's EIP-1967 admin slot (an address
    /// in the low 20 bytes of the word), then the four getters.
    #[tokio::test]
    async fn the_handover_is_read_from_the_admin_slot_and_the_getters() {
        let asserter = Asserter::new();
        asserter.push_success(&U256::from_be_bytes(CTM_ADMIN.into_word().0));
        for answer in [NOTIFIER, CTM, CTM_EXECUTOR, Address::ZERO] {
            asserter.push_success(&Bytes::from(answer.abi_encode()));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let verdict =
            verify_notifier_handover(&provider, &mut result, &manifest_with(notifier_row()), &[])
                .await
                .unwrap();
        assert!(asserter.read_q().is_empty());
        assert_eq!(result.errors, 0);
        assert!(verdict.under_ctm_proxy_admin);
    }

    // ───────────────────────── executor records ─────────────────────────

    /// The records a v35 bootstrap prepare writes for the manifest's own executors.
    fn records_for(manifest: &views::BootstrapManifest) -> UpgradeExecutorsRecord {
        use crate::common::forge::scripts::upgrade_executors::{
            CoordinatorRecord, CoreExecutorRecord, CtmExecutorRecord,
        };
        UpgradeExecutorsRecord {
            core_executor: Some(CoreExecutorRecord {
                address: manifest.coreExecutor,
                create2_salt: SALT,
                initial_owner: manifest.governance,
                proxy_admin: ECO_ADMIN,
            }),
            coordinator: Some(CoordinatorRecord {
                address: manifest.coordinator,
                create2_salt: SALT,
                initial_owner: manifest.governance,
                core_executor: manifest.coreExecutor,
            }),
            ctm_executor: Some(CtmExecutorRecord {
                address: manifest.ctmExecutor,
                create2_salt: SALT,
                initial_owner: manifest.governance,
                chain_type_manager: manifest.ctm,
                ctm_proxy_admin: manifest.ctmProxyAdmin,
                coordinator: manifest.coordinator,
            }),
        }
    }

    fn judge_records(records: &UpgradeExecutorsRecord) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_executor_records_against_manifest(
            &mut result,
            records,
            &manifest_with(notifier_row()),
        );
        result
    }

    #[test]
    fn records_of_the_manifests_executors_pass() {
        let records = records_for(&manifest_with(notifier_row()));
        assert_eq!(judge_records(&records).errors, 0);
        assert_eq!(judge_records(&UpgradeExecutorsRecord::default()).errors, 0);
    }

    /// A record of another deployment — another executor, or a CTM executor built against another
    /// coordinator than the edge binds — is refused before anything is re-derived from it.
    #[test]
    fn records_of_another_deployment_fail() {
        let manifest = manifest_with(notifier_row());
        let mut records = records_for(&manifest);
        records.core_executor.as_mut().unwrap().address = ATTACKER;
        assert_eq!(judge_records(&records).errors, 1);

        let mut records = records_for(&manifest);
        records.ctm_executor.as_mut().unwrap().coordinator = ATTACKER;
        assert_eq!(judge_records(&records).errors, 1);

        let mut records = records_for(&manifest);
        records.coordinator.as_mut().unwrap().address = ATTACKER;
        records.ctm_executor.as_mut().unwrap().address = ATTACKER;
        assert_eq!(judge_records(&records).errors, 2);
    }

    // ───────────────────────── chains below the departing version ─────────────────────────

    /// v0.34.0 and v0.33.0 in the packed encoding.
    const V34: u64 = 0x22_0000_0000;
    const V33: u64 = 0x21_0000_0000;

    fn chain(chain_id: u64, protocol_version: Option<u64>) -> ChainVersion {
        ChainVersion {
            chain_id: U256::from(chain_id),
            protocol_version: protocol_version.map(U256::from),
            verifier: None,
        }
    }

    fn judge_chains(chains: &[ChainVersion]) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_lagging_chains(&mut result, U256::from(V34), chains);
        result
    }

    #[test]
    fn chains_at_the_departing_version_report_nothing() {
        let result = judge_chains(&[chain(270, Some(V34)), chain(271, Some(V34))]);
        assert_eq!((result.errors, result.warnings), (0, 0));
        let result = judge_chains(&[]);
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Informational: every lagging chain is named as a warning, and none of it fails the run.
    #[test]
    fn each_chain_below_the_departing_version_is_a_warning() {
        let result = judge_chains(&[
            chain(270, Some(V34)),
            chain(271, Some(V33)),
            chain(272, Some(V33)),
        ]);
        assert_eq!((result.errors, result.warnings), (0, 2));
        assert!(result.ensure_success().is_ok());
    }

    /// An unreadable version was warned about when it was read, so the verdict adds nothing for
    /// it — but it also does not claim that no chain lags.
    #[test]
    fn an_unreadable_chain_is_neither_lagging_nor_cleared() {
        let result = judge_chains(&[chain(270, None)]);
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// The live read path, in the order it queries: the CTM's Bridgehub, its chain ids, then per
    /// chain its CTM and — for this CTM's chains only — the version the CTM reports, and for a
    /// chain at the departing version its diamond and the verifier it runs: the verifier a
    /// bootstrap release may carry over.
    #[tokio::test]
    async fn the_chains_are_enumerated_through_the_bridgehub_and_filtered_by_ctm() {
        const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
        const OTHER_CTM: Address = Address::repeat_byte(0xC1);
        const DIAMOND: Address = Address::repeat_byte(0xD1);
        const LIVE_VERIFIER: Address = Address::repeat_byte(0xFE);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from(BRIDGEHUB.abi_encode()));
        let ids = vec![U256::from(270u64), U256::from(271u64), U256::from(272u64)];
        asserter.push_success(&Bytes::from(ids.abi_encode()));
        asserter.push_success(&Bytes::from(CTM.abi_encode()));
        asserter.push_success(&Bytes::from(U256::from(V34).abi_encode()));
        asserter.push_success(&Bytes::from(DIAMOND.abi_encode()));
        asserter.push_success(&Bytes::from(LIVE_VERIFIER.abi_encode()));
        asserter.push_success(&Bytes::from(OTHER_CTM.abi_encode()));
        asserter.push_success(&Bytes::from(CTM.abi_encode()));
        asserter.push_success(&Bytes::from(U256::from(V33).abi_encode()));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let chains = read_chain_versions(&provider, &mut result, CTM, U256::from(V34)).await;
        assert!(asserter.read_q().is_empty());
        assert_eq!((result.errors, result.warnings), (0, 0));
        let read: Vec<(U256, Option<U256>, Option<Address>)> = chains
            .iter()
            .map(|c| (c.chain_id, c.protocol_version, c.verifier))
            .collect();
        assert_eq!(
            read,
            vec![
                (
                    U256::from(270u64),
                    Some(U256::from(V34)),
                    Some(LIVE_VERIFIER)
                ),
                (U256::from(272u64), Some(U256::from(V33)), None),
            ]
        );
    }
}
