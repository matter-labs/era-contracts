//! Verification of the one-time BOOTSTRAP edge onto the registry model.
//!
//! This is the only version-specific verifier in the tree, and it is version-specific because the
//! thing it verifies happens exactly once: a CTM that predates the registry model is handed to a
//! `CTMUpgradeExecutor`, and from then on every upgrade of that CTM is an ordinary one
//! ([`super::upgrade`]). There is no second bootstrap to generalise over.
//!
//! Two things follow from an edge whose executors do not hold their domains yet:
//!
//! * governance executes a LIST of handovers around the edge rather than only executor legs, so
//!   the list has to be compared against the one `RegistryBootstrapSequence` derives — see
//!   [`verify_derived_sequence`], which says why that comparison is transitional scaffolding and
//!   must not be generalised. The list is ONE bundle ending in the edge's completion check
//!   (`RegistryBootstrapMigration.validateApplied()`), so an edge that does not complete reverts
//!   the whole bundle; a fork replay asserts what the edge leaves behind a second time
//!   ([`super::applied`]);
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
use super::lifecycle::{
    verify_executor_owners, verify_lifecycle_construction, CoreExecutorReview, CtmExecutorReview,
    LifecycleBindings, LifecycleReview,
};
use super::member_construction::{MemberReview, ReviewedEnv};
use super::members::{verify_engine_and_l2_plan, DepartingMembers, BOOTSTRAP_ENGINES};
use super::package::BootstrapPackage;
use super::provenance::{expect_code_identity, tolerate};
use super::rows::{
    participating, verify_inventory, verify_inventory_construction, Inventory, InventoryReview,
};
use super::upgrade::{
    cross_check, verify_bytecodes_published, verify_proxy_upgrade_transition, verify_release,
    Publication,
};
use super::views::{
    self, BootstrapCall, BridgehubView, CTMUpgradeExecutorView, CtmView,
    RegistryBootstrapMigrationView, ServerNotifierView, ZkChainGettersView,
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
    env: &ReviewedEnv,
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
    let departing = DepartingMembers::verifiers_in_force(
        "the verifier the CTM's chains at the departing version run",
        chains.iter().filter_map(|chain| chain.verifier).collect(),
    );
    let members = MemberReview::new(
        &package.member_records,
        env,
        Some(manifest.ctm),
        package.reported_singletons.bridgehub,
    );
    verify_release(
        provider,
        build,
        &genesis,
        result,
        &members,
        "the release the edge installs",
        manifest.currentRelease,
        salts,
        &departing,
        &mut reviewed,
    )
    .await?;
    // The sequence applies the core transition through the core executor, which applies only a
    // Core-domain object: that domain is fixed here, never read from the object.
    let core_rows = match package.core_transition {
        Some(core_transition_addr) => {
            verify_proxy_upgrade_transition(
                provider,
                build,
                result,
                "the core transition",
                core_transition_addr,
                Inventory::Ecosystem,
                salts,
                &mut reviewed,
            )
            .await?
        }
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
            core_executor: Some(CoreExecutorReview {
                address: manifest.coreExecutor,
                proxy_admin: package.lifecycle.core_proxy_admin,
            }),
            ctm_executor: Some(CtmExecutorReview {
                address: manifest.ctmExecutor,
                ctm: Some(manifest.ctm),
                ctm_proxy_admin: Some(manifest.ctmProxyAdmin),
            }),
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
        &members,
        "the bootstrap migration",
        manifest.upgradeEngine,
        BOOTSTRAP_ENGINES,
        &manifest.l2Plan,
    )
    .await?;

    // ── 3. Authority: the owner both domains land on ──
    //
    // Checked here rather than left to `migrate()`'s own check, so a wrong owner is caught BEFORE
    // governance signs: after `migrate()` both domains are that owner's permanently.
    result.print_info("\n== Bound authority ==");
    verify_executor_owners(
        provider,
        result,
        Some(manifest.governance),
        "the governance the manifest expects",
        &[
            ("the core executor", manifest.coreExecutor),
            ("the CTM executor", manifest.ctmExecutor),
        ],
    )
    .await;

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
    verify_freeze_authority(provider, result, &manifest).await;

    // ── 4. The one-time ServerNotifier handover: a precondition of the edge, half of which
    //    governance cannot perform ──
    result.print_info("\n== Prerequisite: ServerNotifier handover ==");
    let handover = verify_notifier_handover(provider, result, &manifest, &package.calls).await?;

    // ── 5. Readiness: the migration's `validate()` refuses an unpublished L2 dependency ──
    result.print_info("\n== Readiness ==");
    let ctm = CtmView::new(manifest.ctm, provider);
    verify_bytecodes_published(
        provider,
        result,
        &ctm,
        Publication {
            object: package.migration,
            label: "the bootstrap migration",
            required_by: "`RegistryBootstrapMigration.validate()` (run by `migrate()`)",
        },
    )
    .await?;

    // ── 6. The departing state the manifest asserts ──
    result.print_info("\n== Departing state ==");
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
    let outcome = verify_inventory(
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
            reported: package.reported_singletons,
        },
    )
    .await?;
    verify_inventory_construction(provider, build, result, &members, &outcome).await?;

    // ── 7. Chains the edge leaves behind ──
    result.print_info("\n== Chains below the departing version ==");
    judge_lagging_chains(result, manifest.expectedProtocolVersion, &chains);

    // ── 8. The ecosystem leg ──
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
        let outcome = verify_inventory(
            provider,
            build,
            result,
            &InventoryReview {
                inventory: Inventory::Ecosystem,
                rows: core_rows,
                domain_admin: eco_admin_addr,
                anchor: bridgehub,
                departure_unreadable: None,
                reported: Default::default(),
            },
        )
        .await?;
        verify_inventory_construction(provider, build, result, &members, &outcome).await?;
    } else if core_rows.is_none() {
        result.report_ok("no core transition: this edge upgrades no shared singletons");
    }
    members.report_unconsulted(result);

    // ── 9. The calldata governance will actually sign ──
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
/// the manifest's own objects: each must name the manifest's address. (The immutables are held
/// against the manifest by the lifecycle construction check.)
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
    if let Some(record) = &records.ctm_executor {
        check(
            "CTM executor",
            record.address,
            manifest.ctmExecutor,
            "ctmExecutor",
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

/// The CTM takes `freezeChain` / `unfreezeChain` from its own owner and from its Bridgehub's owner
/// ({protocol-docs/ecosystem-upgrade-coordination.md#freezing-a-chain}). Once the edge hands the CTM
/// to its executor, that second caller must be the governance the executors answer to, or freezing
/// the CTM's chains would answer to someone else: an ERROR.
///
/// Reads, in order: the CTM's `BRIDGE_HUB()`, then that Bridgehub's `owner()`.
async fn verify_freeze_authority<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    manifest: &views::BootstrapManifest,
) {
    let Some(bridgehub) = tolerate(
        CtmView::new(manifest.ctm, provider)
            .BRIDGE_HUB()
            .call()
            .await,
        result,
        "the CTM's BRIDGE_HUB(), whose owner may freeze the CTM's chains",
    ) else {
        return;
    };
    let Some(owner) = tolerate(
        BridgehubView::new(bridgehub, provider).owner().call().await,
        result,
        "the owner of the CTM's Bridgehub, who may freeze the CTM's chains",
    ) else {
        return;
    };
    if owner == manifest.governance {
        result.report_ok(&format!(
            "the CTM's Bridgehub {bridgehub} is owned by the manifest's governance {owner}, so \
             freezing the CTM's chains directly answers to the executors' governance"
        ));
    } else {
        result.report_error(&format!(
            "the CTM's Bridgehub {bridgehub} is owned by {owner}, not by the manifest's governance \
             {}: the CTM also takes `freezeChain`/`unfreezeChain` from the Bridgehub's owner, so \
             after the edge freezing its chains would answer to someone other than the executors' \
             governance",
            manifest.governance
        ));
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
/// Every LATER upgrade is an ordinary one, where governance signs at most three executor legs and
/// the executors derive everything else on chain from the objects they apply. That path compares
/// only the run of legs it re-encodes itself, never a list an object derives: see
/// [`upgrade::verify_upgrade_calls`](super::upgrade::verify_upgrade_calls). Do not build new
/// machinery on top of this function — when the bootstrap edge is behind us, it goes.
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
/// outside the run is an ERROR whether declared or not: a `transferOwnership` nomination, a second
/// `applyL1Upgrade`, a `forward` added beside the legitimate calls is exactly how a bundle would
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
                 one — a `transferOwnership` nomination, a second `applyL1Upgrade`, a `forward` \
                 — is authority the review never saw, whether or not the package declares it",
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
mod tests;
