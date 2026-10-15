//! Verification of a RECURRING registry-driven upgrade — the ordinary case, and the one every
//! upgrade after the bootstrap takes.
//!
//! # The two questions, kept apart
//!
//! **What does this upgrade do?** is answered by REVIEWING THE OBJECTS, not by reconstructing
//! them from calldata. An `EcosystemUpgradeOperation` pins the ecosystem inventory, the CTM-domain
//! infrastructure rows and the chain-version edge; a `CTMTransition` pins the release
//! pair and derives the facet cuts and the L2 plan from it. This module reads those objects live
//! and holds each against [`construction`](super::construction) — the reviewed creation code, run
//! on the manifest the object itself serves, must land at the object's address. That covers the
//! object's WHOLE state, so it keeps covering it when someone adds a derived field.
//!
//! **Does the signed transaction invoke the reviewed upgrade at the intended address?** is
//! answered by [`verify_execute_call`] and is deliberately the whole of it: the bundle must call
//! `EcosystemUpgradeExecutor.execute(operation)` on the reviewed coordinator with the reviewed
//! operation, exactly once. The operation's INTERNAL calls are NOT re-derived here — the
//! coordinator and the domain executors derive them on chain from the same pinned object, from
//! audited code, and a second derivation in this tool would be a second implementation to keep in
//! sync. That reconstruction is exactly what the registry model set out to remove.
//!
//! Everything else this module does is the part the objects cannot answer for themselves: that
//! the lifecycle objects the upgrade runs through — the coordinator and both domain executors —
//! are the reviewed ones (their construction, [`super::lifecycle`]; they set immutables, so no
//! codehash identifies them), that authority is bound where the review says, that the live state
//! the upgrade departs from is the state it claims, and that the ecosystem is READY for it (the L2
//! bytecodes published).

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::{SolCall, SolValue};

use crate::common::external_actions::GOVERNANCE_PHASE;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{expect_canonical_construction, ReviewedBuild};
use super::genesis::{judge_release_genesis, ReviewedGenesis};
use super::lifecycle::{verify_lifecycle_construction, LifecycleReview};
use super::package::OperationPackage;
use super::provenance::{expect_code_identity, expect_code_present, tolerate, CodeIdentity};
use super::rows::verify_rows;
use super::shell::verify_shell_kept;
use super::views::{
    BytecodesSupplierView, CTMReleaseView, CTMTransitionView, CTMUpgradeExecutorView,
    CommittedUpgradeView, CoreTransitionView, CoreUpgradeExecutorView, CtmView,
    EcosystemUpgradeExecutorView, EcosystemUpgradeOperationView, ProxyAdminView, ProxyUpgradeRow,
};
use super::{format_semver, render_derived_payloads};

/// Verify a recurring registry-driven upgrade against the live L1 it targets.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
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

    let transition = non_zero(manifest.ctmTransition);
    cross_check(
        result,
        "ctm_transition_addr",
        package.reported_ctm_transition,
        transition,
        "the CTM transition",
    );
    let transition_manifest = match transition {
        Some(address) => {
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
                identity,
                build,
                ArrivingRelease::Installed(&genesis),
                result,
                "the transition the operation carries",
                address,
                salts,
                &mut reviewed,
            )
            .await?
        }
        None => {
            result.report_ok(
                "the operation carries no CTM transition: it moves no chain version, so its CTM \
                 leg is infrastructure only",
            );
            None
        }
    };

    let core_transition = non_zero(manifest.coreTransition);
    cross_check(
        result,
        "core_transition_addr",
        package.reported_core_transition,
        core_transition,
        "the core transition",
    );
    let core_rows = match core_transition {
        Some(address) => {
            verify_core_transition(
                provider,
                identity,
                build,
                result,
                address,
                salts,
                &mut reviewed,
            )
            .await?
        }
        None => {
            result.report_ok(
                "the operation carries no core transition: it upgrades no shared singletons",
            );
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
    let coordinator = EcosystemUpgradeExecutorView::new(package.coordinator, provider);
    let Some(ctm_executor_addr) = tolerate(
        coordinator.ctmExecutor().call().await,
        result,
        "the coordinator's bound CTM executor",
    ) else {
        return Ok(());
    };
    if ctm_executor_addr.is_zero() {
        result.report_error(
            "the coordinator has no bound CTM executor: `execute` reverts before it applies \
             anything, so this upgrade could not run",
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
                "the package does not name `{field}`, so {what} cannot be held against anything \
                 the review fixes, nor can the CTM executor's recorded binding to it"
            ));
        }
    }

    let bindings = verify_lifecycle_construction(
        provider,
        build,
        result,
        &LifecycleReview {
            owner: expected_governance_owner,
            coordinator: package.coordinator,
            core_executor: package.lifecycle.core_executor,
            core_proxy_admin: package.lifecycle.core_proxy_admin,
            ctm_executor: ctm_executor_addr,
            ctm: package.reported_ctm,
            ctm_proxy_admin: package.reported_ctm_proxy_admin,
            records: package.executor_records.clone(),
        },
        &mut reviewed,
    )
    .await?;
    let Some(core_executor_addr) = bindings.core_executor else {
        return Ok(());
    };
    let Some(core_admin_addr) = bindings.core_proxy_admin else {
        return Ok(());
    };
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
    expect_domains_answer_to(
        provider,
        result,
        package.coordinator,
        core_executor_addr,
        ctm_executor_addr,
    )
    .await;

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

    // ── 3. The state the upgrade departs from ──
    result.print_info("\n== Departing state ==");
    let ctm = CtmView::new(ctm_addr, provider);
    if let Some(edge) = &transition_manifest {
        let Some(live_version) = tolerate(
            ctm.protocolVersion().call().await,
            result,
            "the CTM's live protocol version",
        ) else {
            return Ok(());
        };
        if live_version == edge.old_version {
            result.report_ok(&format!(
                "the CTM is at the transition's departing version {}",
                format_semver(live_version)
            ));
        } else {
            result.report_error(&format!(
                "the CTM is at version {} but the transition departs from {}: the version edge \
                 is refused on chain",
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
            return Ok(());
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

    verify_rows(
        provider,
        result,
        "CTM-domain row",
        &ctm_rows,
        ctm_admin_addr,
    )
    .await?;
    verify_rows(
        provider,
        result,
        "ecosystem row",
        &core_rows,
        core_admin_addr,
    )
    .await?;

    // ── 4. Readiness: what `execute` requires that no object can assert ──
    result.print_info("\n== Readiness ==");
    if let Some(transition_addr) = transition {
        verify_bytecodes_published(provider, result, &ctm, transition_addr).await?;
    } else {
        result.report_ok("no transition: no L2 bytecodes need to be published");
    }

    // ── 5. The L2 proxy logic chains crossing the edge keep ──
    if let Some(edge) = &transition_manifest {
        result.print_info("\n== L2 system-proxy shell ==");
        verify_shell_kept(
            provider,
            identity,
            genesis.image.as_ref().ok(),
            result,
            &ctm,
            &edge.manifest,
        )
        .await;
    }

    // ── 6. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    verify_execute_call(package, result);

    // ── 7. The calls no object describes ──
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
/// Governance signs one derived call: `coordinator.execute(operation)`. It is re-ENCODED here from
/// the reviewed coordinator and the reviewed operation and compared byte for byte, so a bundle
/// naming a different operation or a different coordinator is a finding rather than a passing
/// shape check.
///
/// Every other call in the bundle must be a declared governance external action. Those carry
/// authority the upgrade objects do not describe, so they are the reviewer's to read — but a call
/// that is neither the executor call nor a declared action is an ERROR: it is how a bundle would
/// smuggle an unreviewed instruction past a reviewer reading only the operation.
fn verify_execute_call(package: &OperationPackage, result: &mut VerificationResult) {
    let expected = EcosystemUpgradeExecutorView::executeCall {
        _operation: package.operation,
    }
    .abi_encode();

    let matches = package
        .calls
        .iter()
        .filter(|call| {
            call.target == package.coordinator && call.value.is_zero() && call.data == expected
        })
        .count();
    match matches {
        1 => result.report_ok(&format!(
            "the bundle calls execute({}) on the reviewed coordinator {} exactly once",
            package.operation, package.coordinator
        )),
        0 => result.report_error(&format!(
            "the bundle never calls execute({}) on the reviewed coordinator {}: the bundle \
             governance would sign does not drive the reviewed upgrade",
            package.operation, package.coordinator
        )),
        n => result.report_error(&format!(
            "the bundle calls execute({}) {n} times: the second would revert, and a duplicated \
             executor call is not a bundle the prepare produces",
            package.operation
        )),
    }

    for call in &package.calls {
        if call.target == package.coordinator && call.data == expected {
            continue;
        }
        let declared = package
            .external_actions
            .iter()
            .any(|action| action.phase == GOVERNANCE_PHASE && action.is_call(call));
        if !declared {
            result.report_error(&format!(
                "the bundle calls {} (selector 0x{}), which is neither this upgrade's executor \
                 call nor a declared governance external action: the bundle carries an \
                 instruction no part of this review accounts for",
                call.target,
                alloy::hex::encode(call.data.get(..4).unwrap_or_default())
            ));
        }
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
    identity: &CodeIdentity,
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
        identity,
        result,
        label,
        transition,
        "CTMTransition",
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
            verify_release(
                provider,
                identity,
                build,
                genesis,
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

/// A release's provenance and construction, re-derived from the manifest it serves, and its
/// genesis against the reviewed one.
#[allow(clippy::too_many_arguments)]
async fn verify_release<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    genesis: &ReviewedGenesis,
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
    judge_release_genesis(result, label, &manifest, genesis);
    Ok(())
}

/// The core transition's provenance and construction, plus the rows it pins.
#[allow(clippy::too_many_arguments)]
async fn verify_core_transition<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    core_transition: Address,
    salts: &[B256],
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Vec<ProxyUpgradeRow>> {
    expect_code_identity(
        provider,
        identity,
        result,
        "the core transition",
        core_transition,
        "CoreTransition",
    )
    .await?;
    let view = CoreTransitionView::new(core_transition, provider);
    let manifest = match view.getManifest().call().await {
        Ok(m) => m,
        Err(e) => {
            result.report_error(&format!(
                "the core transition at {core_transition} does not answer `getManifest()` ({e}): its \
                 construction cannot be verified"
            ));
            return Ok(Vec::new());
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
    Ok(manifest
        .proxyUpgrades
        .into_iter()
        .filter(|row| !row.implNew.is_zero())
        .collect())
}

/// Every bytecode the transition's L2 transaction depends on must ALREADY be published on the
/// CTM's supplier: `applyOperation` requires it, and an unpublished dependency fails the committed
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

/// Both domain executors' LIVE `coordinator()` — `setCoordinator` moves it after construction —
/// against the reviewed coordinator: a domain answering to another one reverts `applyOperation`.
pub(super) async fn expect_domains_answer_to<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    coordinator: Address,
    core_executor: Address,
    ctm_executor: Address,
) {
    for (label, bound) in [
        (
            "the CTM executor",
            tolerate(
                CTMUpgradeExecutorView::new(ctm_executor, provider)
                    .coordinator()
                    .call()
                    .await,
                result,
                "the CTM executor's coordinator",
            ),
        ),
        (
            "the core executor",
            tolerate(
                CoreUpgradeExecutorView::new(core_executor, provider)
                    .coordinator()
                    .call()
                    .await,
                result,
                "the core executor's coordinator",
            ),
        ),
    ] {
        match bound {
            Some(bound) if bound == coordinator => {
                result.report_ok(&format!("{label} answers to the reviewed coordinator"))
            }
            Some(bound) => result.report_error(&format!(
                "{label} answers to coordinator {bound}, not the reviewed {coordinator}: its \
                 `applyOperation` would revert"
            )),
            None => {}
        }
    }
}

/// The governance address the whole lifecycle answers to, held against the review.
pub(super) async fn verify_governance_owner<P: Provider>(
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

    let pending_owners = [
        (
            "the coordinator",
            tolerate(
                EcosystemUpgradeExecutorView::new(coordinator, provider)
                    .pendingOwner()
                    .call()
                    .await,
                result,
                "the coordinator's pending owner",
            ),
        ),
        (
            "the core executor",
            tolerate(
                CoreUpgradeExecutorView::new(core_executor, provider)
                    .pendingOwner()
                    .call()
                    .await,
                result,
                "the core executor's pending owner",
            ),
        ),
        (
            "the CTM executor",
            tolerate(
                CTMUpgradeExecutorView::new(ctm_executor, provider)
                    .pendingOwner()
                    .call()
                    .await,
                result,
                "the CTM executor's pending owner",
            ),
        ),
    ];
    for (label, pending) in pending_owners {
        expect_no_nomination(result, label, pending);
    }

    // The coordinator's owner is the address that signs the bundle, so every domain must answer
    // to it: one lifecycle under two owners cannot complete.
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

/// A lifecycle object's `pendingOwner()`: a nominee could accept after the review and take the
/// lifecycle with it.
pub(super) fn expect_no_nomination(
    result: &mut VerificationResult,
    label: &str,
    pending: Option<Address>,
) {
    match pending {
        Some(pending) if pending.is_zero() => {
            result.report_ok(&format!("{label} has no pending owner"))
        }
        Some(pending) => result.report_error(&format!(
            "{label} has a pending owner {pending}: a nomination is outstanding that could take \
             the lifecycle this upgrade runs through"
        )),
        None => {}
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
/// the manifest is what executes. A disagreement means the reviewer reviewed a different object
/// from the one governance would drive.
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

fn non_zero(address: Address) -> Option<Address> {
    (!address.is_zero()).then_some(address)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::U256;

    use super::super::package::RegistryPackage;

    use crate::common::external_actions::ExternalAction;
    use crate::common::governance_calls::GovernanceCall;

    const OPERATION: Address = Address::repeat_byte(0xA0);
    const COORDINATOR: Address = Address::repeat_byte(0xC0);

    fn execute_call(coordinator: Address, operation: Address) -> GovernanceCall {
        GovernanceCall {
            target: coordinator,
            value: U256::ZERO,
            data: EcosystemUpgradeExecutorView::executeCall {
                _operation: operation,
            }
            .abi_encode(),
        }
    }

    fn package(
        calls: Vec<GovernanceCall>,
        external_actions: Vec<ExternalAction>,
    ) -> OperationPackage {
        OperationPackage {
            operation: OPERATION,
            coordinator: COORDINATOR,
            ctm_key: "zksync_os".to_string(),
            reported_ctm_transition: None,
            reported_core_transition: None,
            reported_ctm_executor: None,
            reported_ctm: None,
            reported_ctm_proxy_admin: None,
            calls,
            external_actions,
            create2_salts: Vec::new(),
            lifecycle: Default::default(),
            force_deployments_data: None,
            executor_records: Default::default(),
        }
    }

    fn well_formed() -> OperationPackage {
        package(vec![execute_call(COORDINATOR, OPERATION)], Vec::new())
    }

    fn extra() -> GovernanceCall {
        GovernanceCall {
            target: Address::repeat_byte(0xEE),
            value: U256::ZERO,
            data: vec![0xde, 0xad, 0xbe, 0xef],
        }
    }

    /// The current-owner half of the lifecycle check: an outstanding nomination on any lifecycle
    /// object fails the run, a cleared one passes, an unreadable one was reported when read.
    #[test]
    fn a_pending_nomination_on_a_lifecycle_object_fails() {
        let mut result = VerificationResult::default();
        expect_no_nomination(&mut result, "the coordinator", Some(Address::ZERO));
        assert_eq!((result.errors, result.warnings), (0, 0));
        expect_no_nomination(&mut result, "the coordinator", None);
        assert_eq!((result.errors, result.warnings), (0, 0));
        expect_no_nomination(
            &mut result,
            "the CTM executor",
            Some(Address::repeat_byte(0xBA)),
        );
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn the_execute_call_passes() {
        let mut result = VerificationResult::default();
        verify_execute_call(&well_formed(), &mut result);
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
    }

    /// The selector the check rests on must be the coordinator's real one, so a signature change
    /// is caught here rather than by a package that silently stops matching. Transcribed as well
    /// as derived, so the `sol!` mirror cannot drift with it.
    #[test]
    fn the_execute_selector_is_the_coordinators() {
        let call = execute_call(COORDINATOR, OPERATION);
        assert_eq!(&call.data[..4], &[0x4b, 0x64, 0xe4, 0x92]);
        assert_eq!(
            &call.data[..4],
            &alloy::primitives::keccak256(b"execute(address)")[..4]
        );
    }

    /// THE substitution this check exists to catch: a bundle that drives a DIFFERENT operation
    /// through the reviewed coordinator. Everything about the shape is right; only the address
    /// the reviewer approved is missing.
    #[test]
    fn a_bundle_driving_a_different_operation_fails() {
        let impostor = Address::repeat_byte(0xBB);
        let mut result = VerificationResult::default();
        verify_execute_call(
            &package(vec![execute_call(COORDINATOR, impostor)], Vec::new()),
            &mut result,
        );
        // The reviewed call is missing, and the impostor call is undeclared.
        assert_eq!(result.errors, 2);
        assert!(result.ensure_success().is_err());
    }

    /// The same upgrade driven through a coordinator the review did not approve: the operation is
    /// right, the place it executes is not.
    #[test]
    fn a_bundle_driving_the_operation_through_another_coordinator_fails() {
        let impostor = Address::repeat_byte(0xDD);
        let mut result = VerificationResult::default();
        verify_execute_call(
            &package(vec![execute_call(impostor, OPERATION)], Vec::new()),
            &mut result,
        );
        assert_eq!(result.errors, 2);
    }

    /// An extra call nobody declared rides along with a perfectly good executor call. It must fail
    /// the run, not be reported as a note beside a successful review.
    #[test]
    fn an_undeclared_extra_call_fails_the_run() {
        let mut pkg = well_formed();
        pkg.calls.push(extra());
        let mut result = VerificationResult::default();
        verify_execute_call(&pkg, &mut result);
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }

    /// The same extra call, DECLARED: an independently authorized action rides along and is the
    /// reviewer's to read, so it passes the calldata check and is printed rather than flagged —
    /// before the executor call (the merger's extras) as well as after it (a CTM prepare's own).
    #[test]
    fn a_declared_external_action_rides_along() {
        for at_front in [true, false] {
            let mut pkg = well_formed();
            if at_front {
                pkg.calls.insert(0, extra());
            } else {
                pkg.calls.push(extra());
            }
            pkg.external_actions.push(ExternalAction::governance(
                "an admin hop",
                "governance",
                &extra(),
            ));
            let mut result = VerificationResult::default();
            verify_execute_call(&pkg, &mut result);
            assert_eq!(result.errors, 0);
        }
    }

    /// An `admin` declaration rides no governance bundle, so it does not excuse the same call
    /// appearing in it.
    #[test]
    fn an_admin_declaration_does_not_account_for_a_bundle_call() {
        let mut pkg = well_formed();
        pkg.calls.push(extra());
        let mut declared = ExternalAction::governance("an admin hop", "governance", &extra());
        declared.phase = "admin".to_string();
        pkg.external_actions.push(declared);
        let mut result = VerificationResult::default();
        verify_execute_call(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    /// A bundle that drives the reviewed upgrade TWICE: the second call reverts on chain, so a
    /// bundle carrying it is not one the prepare produced.
    #[test]
    fn a_duplicated_execute_call_fails() {
        let mut pkg = well_formed();
        pkg.calls.push(execute_call(COORDINATOR, OPERATION));
        let mut result = VerificationResult::default();
        verify_execute_call(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    /// An executor call carrying value is not the call the merge derives, and `execute` is not
    /// payable.
    #[test]
    fn an_execute_call_carrying_value_is_not_the_reviewed_call() {
        let mut pkg = well_formed();
        pkg.calls[0].value = U256::from(1);
        let mut result = VerificationResult::default();
        verify_execute_call(&pkg, &mut result);
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn an_empty_bundle_fails() {
        let mut result = VerificationResult::default();
        verify_execute_call(&package(Vec::new(), Vec::new()), &mut result);
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
            "core_transition_addr",
            Some(Address::repeat_byte(0x11)),
            None,
            "the core transition",
        );
        assert_eq!(result.errors, 1);
    }

    // ───────────────── a release with no verifier module of its own ─────────────────
    //
    // `CTMUpgrade_v36 is DefaultCTMUpgrade {}` — the first registry-driven release after the
    // bootstrap is an empty subclass of the base prepare. Its package therefore reaches THIS
    // path, and these drive the whole of it that runs without a chain: the merged TOML the
    // prepare emits, loaded through the same entry point production uses, and its calldata held
    // against the two addresses the package names.
    //
    // Nothing here names a release. That is the point: the package format carries no protocol
    // version (the version lives in the `CTMTransition`, read on chain), so the same code serves
    // v36 and everything after it. A release that needed its own module would fail these.

    /// Writes `body` to a scratch file and loads it the way `registry::verify` does.
    fn load_package(body: &str) -> RegistryPackage {
        let dir = std::env::temp_dir().join(format!(
            "protocol-ops-operation-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ecosystem.toml");
        std::fs::write(&path, body).unwrap();
        RegistryPackage::load(&path).expect("a prepared release package must load")
    }

    fn bundle_hex(call: &GovernanceCall) -> String {
        format!(
            "0x{}",
            alloy::hex::encode(crate::common::governance_calls::encode_calls(
                std::slice::from_ref(call)
            ))
        )
    }

    /// The merged prepare output of an ordinary release, with the executor call the merge DERIVES
    /// from the operation's address — real ABI-encoded `Call[]` hex, not a placeholder.
    fn prepared_release_package() -> String {
        format!(
            "[operation]\n\
             operation_addr = \"{OPERATION:#x}\"\n\
             coordinator_addr = \"{COORDINATOR:#x}\"\n\
             [ctms.zksync_os.registry]\n\
             ctm_transition_addr = \"0x00000000000000000000000000000000000000cc\"\n\
             bootstrap_migration_addr = \"0x0000000000000000000000000000000000000000\"\n\
             [core.registry]\n\
             core_transition_addr = \"0x00000000000000000000000000000000000000ee\"\n\
             [governance_calls]\n\
             calls = \"{}\"\n",
            bundle_hex(&execute_call(COORDINATOR, OPERATION)),
        )
    }

    /// End to end over everything that does not need a chain: the package loads as an ordinary
    /// operation, and the calldata governance would sign passes the check that it invokes the
    /// reviewed upgrade at the reviewed address — with no module, branch or constant naming the
    /// release anywhere in this path.
    #[test]
    fn a_prepared_release_verifies_through_the_general_path() {
        let RegistryPackage::Operation(package) = load_package(&prepared_release_package()) else {
            panic!("an ordinary release must verify as an operation");
        };
        assert_eq!(package.operation, OPERATION);
        assert_eq!(package.coordinator, COORDINATOR);

        let mut result = VerificationResult::default();
        verify_execute_call(&package, &mut result);
        assert_eq!(
            result.errors, 0,
            "a prepared release must pass the calldata check"
        );
        assert_eq!(result.warnings, 0);
        assert!(result.ensure_success().is_ok());
    }

    /// And the check still bites on that package: a bundle that drives a DIFFERENT operation
    /// through the same coordinator fails, so the test above is not passing on a check that
    /// accepts anything.
    #[test]
    fn the_general_path_still_rejects_a_substituted_operation() {
        let impostor = Address::repeat_byte(0x9E);
        let body = prepared_release_package().replace(
            &bundle_hex(&execute_call(COORDINATOR, OPERATION)),
            &bundle_hex(&execute_call(COORDINATOR, impostor)),
        );
        let RegistryPackage::Operation(package) = load_package(&body) else {
            panic!("still an operation package");
        };
        let mut result = VerificationResult::default();
        verify_execute_call(&package, &mut result);
        assert!(
            result.errors > 0,
            "a substituted operation must fail the run"
        );
        assert!(result.ensure_success().is_err());
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
