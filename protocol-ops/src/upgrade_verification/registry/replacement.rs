//! Verification of a transition REPLACEMENT package: governance repairing a committed transition
//! through `ChainTypeManager.replaceUpgradeTransition`, forwarded by the CTM executor (see
//! `protocol-docs/ecosystem-upgrade-coordination.md#replacing-a-committed-transition`).
//!
//! The replacement is an ordinary write-once `CTMTransition`, so its identity is checked exactly
//! as an upgrade's transition leg is ([`super::upgrade::verify_transition`]). What it is HELD
//! AGAINST differs: not the CTM's current release, but the transition it replaces and the onward
//! path — the CTM's own compare-and-replace checks, judged over live reads before governance
//! signs ([`judge_replacement_state`]). It lands on an existing release, so it deploys none and
//! no genesis is judged here; the destination is checked to BE the continuation release.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;

use crate::common::external_actions::{ExternalAction, GOVERNANCE_PHASE};
use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::ReviewedBuild;
use super::format_semver;
use super::genesis::GenesisImage;
use super::lifecycle::{
    verify_executor_owners, verify_lifecycle_construction, CtmExecutorReview, LifecycleReview,
};
use super::member_construction::{MemberReview, ReviewedEnv};
use super::package::{DeadlineChange, RecoveredReplacement, ReplacementPackage};
use super::provenance::{expect_code_present, tolerate};
use super::shell::verify_shell_kept;
use super::upgrade::{
    cross_check, verify_bytecodes_published, verify_transition, ArrivingRelease, Publication,
};
use super::views::{CTMTransitionView, CtmView};

/// Verify a transition replacement against the live L1 it targets.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    image: Option<&GenesisImage>,
    package: &ReplacementPackage,
    expected_governance_owner: Option<Address>,
    salts: &[B256],
    env: &ReviewedEnv,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let mut reviewed: BTreeMap<Address, String> = BTreeMap::new();
    let forward = &package.forward;
    let members = MemberReview::new(&package.member_records, env, Some(forward.ctm), None);

    result.print_info("== Package ==");
    result.report_ok(&format!(
        "a transition replacement on CTM section [{}]: replaces {} with {} on CTM {}, forwarded \
         by {} (bundle call {})",
        package.ctm_key,
        forward.expected,
        forward.replacement,
        forward.ctm,
        forward.executor,
        forward.index
    ));
    for (field, reported, actual, what) in [
        (
            "replaced_transition_addr",
            package.reported_replaced,
            forward.expected,
            "the transition being replaced",
        ),
        (
            "replacement_transition_addr",
            package.reported_replacement,
            forward.replacement,
            "the replacement",
        ),
        (
            "ctm_transition_addr",
            package.reported_ctm_transition,
            forward.replacement,
            "the replacement",
        ),
        (
            "ctm_upgrade_executor_addr",
            package.reported_ctm_executor,
            forward.executor,
            "the CTM executor the forward targets",
        ),
        (
            "chain_type_manager_proxy",
            package.reported_ctm,
            forward.ctm,
            "the CTM the forward calls",
        ),
    ] {
        cross_check(result, field, reported, Some(actual), what);
    }

    // ── 1. The replacement, and the transition it replaces ──
    result.print_info("\n== Object provenance and construction ==");
    let replacement_edge = verify_transition(
        provider,
        build,
        ArrivingRelease::Existing,
        result,
        &members,
        "the replacement transition",
        forward.replacement,
        salts,
        &mut reviewed,
    )
    .await?;
    let replacement = replacement_edge.as_ref().map(|edge| TransitionFacts {
        address: forward.replacement,
        old_version: edge.old_version,
        new_version: edge.new_version,
        from_release: edge.manifest.fromRelease,
        new_release: edge.manifest.newRelease,
        deadline: edge.manifest.oldProtocolVersionDeadline,
    });
    if let Some(replacement) = &replacement {
        cross_check(
            result,
            "ctm_release_addr",
            package.reported_release,
            Some(replacement.new_release),
            "the release the replacement lands on",
        );
        cross_check_version(
            result,
            "new_protocol_version",
            package.reported_new_version,
            replacement.new_version,
        );
    }
    // The replaced transition is a live commitment, possibly built by an earlier commit, so it is
    // read through the same getters the CTM reads, not held to this commit's build.
    let expected = read_transition(
        provider,
        result,
        "the transition being replaced",
        forward.expected,
    )
    .await?;
    if let Some(expected) = &expected {
        cross_check_version(
            result,
            "old_protocol_version",
            package.reported_old_version,
            expected.old_version,
        );
    }

    // ── 2. Authority: the CTM executor the forward runs through, and its lifecycle ──
    result.print_info("\n== Bound authority ==");
    let ctm = CtmView::new(forward.ctm, provider);
    let ctm_owner = tolerate(ctm.owner().call().await, result, "the CTM's owner");
    match tolerate(
        ctm.pendingOwner().call().await,
        result,
        "the CTM's pending owner",
    ) {
        Some(pending) if pending.is_zero() => result.report_ok("the CTM has no pending owner"),
        Some(pending) => result.report_error(&format!(
            "the CTM has a pending owner {pending}: a nomination is outstanding that could take \
             the CTM out from under the executor this replacement runs through"
        )),
        None => {}
    }
    // The forward runs through the CTM executor alone; no core executor is involved.
    verify_lifecycle_construction(
        provider,
        build,
        result,
        &LifecycleReview {
            owner: expected_governance_owner,
            core_executor: None,
            ctm_executor: Some(CtmExecutorReview {
                address: forward.executor,
                ctm: package.reported_ctm,
                ctm_proxy_admin: package.reported_ctm_proxy_admin,
            }),
            records: package.executor_records.clone(),
        },
        &mut reviewed,
    )
    .await?;
    verify_executor_owners(
        provider,
        result,
        expected_governance_owner,
        "the reviewed governance",
        &[("the CTM executor", forward.executor)],
    )
    .await;

    // ── 3. The commitment being replaced, and where the replacement lands ──
    result.print_info("\n== Departing state ==");
    if let (Some(expected), Some(replacement)) = (expected, replacement) {
        if let Some(facts) = read_replacement_facts(
            provider,
            result,
            &ctm,
            expected,
            replacement,
            forward.deadline,
        )
        .await?
        {
            judge_replacement_state(result, &facts);
        }
    }

    // ── 4. Readiness ──
    result.print_info("\n== Readiness ==");
    verify_bytecodes_published(
        provider,
        result,
        &ctm,
        Publication {
            object: forward.replacement,
            label: "the replacement",
            required_by: "`ChainTypeManager.replaceUpgradeTransition`",
        },
    )
    .await?;

    // ── 5. The L2 proxy logic chains crossing the edge keep ──
    if let Some(edge) = &replacement_edge {
        result.print_info("\n== L2 system-proxy shell ==");
        verify_shell_kept(
            provider,
            build.identity(),
            image,
            result,
            &ctm,
            &edge.manifest,
        )
        .await;
    }

    // ── 6. The calldata governance will actually sign ──
    result.print_info("\n== Governance calldata ==");
    judge_replacement_calls(
        result,
        forward,
        &package.calls,
        &package.external_actions,
        ctm_owner,
    );
    result.print_info(&format!(
        "  {} declared external action(s), for review:",
        package.external_actions.len()
    ));
    for action in &package.external_actions {
        result.print_info(&format!("    · {}", action.describe()));
    }
    members.report_unconsulted(result);
    Ok(())
}

/// A transition as the CTM's compare-and-replace reads it.
#[derive(Debug, Clone)]
pub(super) struct TransitionFacts {
    pub(super) address: Address,
    pub(super) old_version: U256,
    pub(super) new_version: U256,
    pub(super) from_release: Address,
    pub(super) new_release: Address,
    /// The pinned `oldProtocolVersionDeadline`.
    pub(super) deadline: U256,
}

/// The live state a replacement is judged against.
#[derive(Debug, Clone)]
pub(super) struct ReplacementFacts {
    pub(super) ctm_version: U256,
    pub(super) current_release: Address,
    pub(super) expected: TransitionFacts,
    pub(super) replacement: TransitionFacts,
    /// `upgradeTransition[expected.old_version]` now.
    pub(super) committed: Address,
    /// Read only when the replacement lands below the CTM's version: the edge committed onward
    /// from its target and that edge's `fromRelease` (`None` when unreadable, already reported).
    pub(super) onward: Option<(Address, Option<Address>)>,
    /// `protocolVersionDeadline(expected.old_version)` now (`None` when unreadable).
    pub(super) effective_deadline: Option<U256>,
    /// The `setProtocolVersionDeadline` riding the same forward.
    pub(super) deadline_change: Option<DeadlineChange>,
}

/// The CTM's replacement checks over live facts, plus the deadline report. Every refusal the CTM
/// would revert with is an ERROR here.
pub(super) fn judge_replacement_state(result: &mut VerificationResult, facts: &ReplacementFacts) {
    let expected = &facts.expected;
    let replacement = &facts.replacement;
    let departure = format_semver(expected.old_version);

    if facts.committed == expected.address {
        result.report_ok(&format!(
            "the CTM commits the expected transition {} for departures from {departure}",
            expected.address
        ));
    } else if facts.committed.is_zero() {
        result.report_error(&format!(
            "the CTM commits nothing for departures from {departure}: there is nothing to \
             replace, and `replaceUpgradeTransition` reverts (`TransitionNotCommitted`)"
        ));
    } else {
        result.report_error(&format!(
            "the CTM commits {} for departures from {departure}, not the expected {}: the \
             proposal is stale and compare-and-replace reverts (`TransitionNotCommitted`)",
            facts.committed, expected.address
        ));
    }
    if replacement.address == expected.address {
        result.report_error(
            "the replacement IS the transition it replaces: `replaceUpgradeTransition` reverts \
             (`UpgradeTransitionUnchanged`)",
        );
    }
    if expected.old_version < facts.ctm_version {
        result.report_ok(&format!(
            "the departure {departure} is below the CTM's version {}",
            format_semver(facts.ctm_version)
        ));
    } else {
        result.report_error(&format!(
            "the departure {departure} is not below the CTM's version {}: a committed departure \
             always is, so this one is not a commitment that can be repaired",
            format_semver(facts.ctm_version)
        ));
    }

    // The same departure: the replaced transition's source release, NOT the CTM's current one.
    if replacement.from_release == expected.from_release {
        result.report_ok(&format!(
            "the replacement departs from the replaced transition's own source release {} (the \
             CTM's current release is {})",
            expected.from_release, facts.current_release
        ));
    } else {
        result.report_error(&format!(
            "the replacement departs from release {} but the replaced transition from {}: a \
             replacement departs from the SAME release object (`TransitionReleaseMismatch`)",
            replacement.from_release, expected.from_release
        ));
    }
    if replacement.deadline == expected.deadline {
        result.report_ok(&format!(
            "the replacement pins the replaced transition's deadline {}",
            format_deadline(expected.deadline)
        ));
    } else {
        result.report_error(&format!(
            "the replacement pins deadline {} but the replaced transition {}: a deadline change \
             is a separate `setProtocolVersionDeadline` (`TransitionDeadlineMismatch`)",
            format_deadline(replacement.deadline),
            format_deadline(expected.deadline)
        ));
    }

    // Onward: no earlier than what it replaces, on a release a chain can continue from.
    let target = format_semver(replacement.new_version);
    if replacement.new_version >= expected.new_version {
        result.report_ok(&format!(
            "the replacement lands at {target}, no earlier than the replaced {}",
            format_semver(expected.new_version)
        ));
    } else {
        result.report_error(&format!(
            "the replacement lands at {target}, earlier than the replaced {} \
             (`ProtocolVersionTooSmall`)",
            format_semver(expected.new_version)
        ));
    }
    if replacement.new_version == facts.ctm_version {
        if replacement.new_release == facts.current_release {
            result.report_ok(&format!(
                "the replacement lands at the CTM's version on its current release {}",
                facts.current_release
            ));
        } else {
            result.report_error(&format!(
                "the replacement lands at the CTM's version {target} on release {}, which is not \
                 the CTM's current release {} (`TransitionReleaseMismatch`)",
                replacement.new_release, facts.current_release
            ));
        }
    } else if replacement.new_version > facts.ctm_version {
        result.report_error(&format!(
            "the replacement lands at {target}, beyond the CTM's version {}: nothing departs a \
             version the CTM has not reached (`NoCommittedUpgradeCutForVersion`)",
            format_semver(facts.ctm_version)
        ));
    } else {
        match facts.onward {
            Some((onward, _)) if onward.is_zero() => result.report_error(&format!(
                "nothing is committed onward from {target}: a chain landing there could not \
                 continue (`NoCommittedUpgradeCutForVersion`)"
            )),
            Some((onward, Some(source))) if source == replacement.new_release => {
                result.report_ok(&format!(
                    "the replacement lands on release {source}, the source of the edge {onward} \
                     committed onward from {target}"
                ))
            }
            Some((onward, Some(source))) => result.report_error(&format!(
                "the replacement lands on release {} but the edge {onward} committed onward from \
                 {target} departs from {source}: chains landing there would be disconnected from \
                 the path to the current release (`TransitionReleaseMismatch`)",
                replacement.new_release
            )),
            _ => {}
        }
    }

    // The deadline: unchanged by the replacement itself, unless the batch moves it.
    if let Some(effective) = facts.effective_deadline {
        let source = if effective == expected.deadline {
            "the pinned deadline, which the replacement keeps"
        } else {
            "an override of the pinned deadline, which survives the replacement"
        };
        result.print_info(&format!(
            "  the departure {departure}'s effective deadline is {} ({source})",
            format_deadline(effective)
        ));
    }
    if let Some(change) = facts.deadline_change {
        if change.protocol_version != expected.old_version {
            result.report_error(&format!(
                "the forward also sets the deadline of {}, not of the departure {departure} being \
                 replaced: an unrelated deadline change rides the replacement",
                format_semver(change.protocol_version)
            ));
        } else if change.timestamp.is_zero() {
            result.report_ok(&format!(
                "the forward clears the departure {departure}'s deadline override: its effective \
                 deadline falls back to the pinned {}",
                format_deadline(expected.deadline)
            ));
        } else {
            result.report_ok(&format!(
                "the forward sets the departure {departure}'s deadline to {}",
                format_deadline(change.timestamp)
            ));
        }
    }
}

/// The calldata verdict: the forward runs through the executor that owns the CTM, and every other
/// call of the bundle is a declared governance external action reaching neither of them.
///
/// `ctm_owner` is the CTM's live owner (`None` when unreadable, already reported).
pub(super) fn judge_replacement_calls(
    result: &mut VerificationResult,
    forward: &RecoveredReplacement,
    calls: &[GovernanceCall],
    declared: &[ExternalAction],
    ctm_owner: Option<Address>,
) {
    match ctm_owner {
        Some(owner) if owner == forward.executor => result.report_ok(&format!(
            "the forward targets {owner}, the CTM executor that owns the CTM"
        )),
        Some(owner) => result.report_error(&format!(
            "the forward targets {}, but the CTM is owned by {owner}: governance would be \
             forwarding through something that is not the CTM's executor, and the inner call \
             reverts `onlyOwner`",
            forward.executor
        )),
        None => {}
    }

    let mut extras = 0usize;
    for (index, call) in calls.iter().enumerate() {
        if index == forward.index {
            continue;
        }
        let selector = alloy::hex::encode(call.data.get(..4).unwrap_or_default());
        if call.target == forward.executor || call.target == forward.ctm {
            extras += 1;
            result.report_error(&format!(
                "the bundle calls {} (selector 0x{selector}) besides the replacement's forward: \
                 the CTM and its executor take exactly the reviewed forward, so an extra call to \
                 either is authority the review never saw, declared or not",
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
                    "the bundle calls {} (selector 0x{selector}), which is neither the \
                     replacement's forward nor a declared governance external action: the bundle \
                     carries an instruction no part of this review accounts for",
                    call.target
                ));
            }
        }
    }
    if extras == 0 {
        result.report_ok(
            "every other submitted call is a declared external action outside the CTM domain",
        );
    }
}

/// The CTM's reads of a live transition — `oldProtocolVersion`, `newProtocolVersion`,
/// `fromRelease`, `newRelease`, `oldProtocolVersionDeadline`.
async fn read_transition<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
) -> anyhow::Result<Option<TransitionFacts>> {
    if !expect_code_present(provider, result, label, address).await? {
        return Ok(None);
    }
    let view = CTMTransitionView::new(address, provider);
    let what = |getter: &str| format!("{label}'s {getter}()");
    let (
        Some(old_version),
        Some(new_version),
        Some(from_release),
        Some(new_release),
        Some(deadline),
    ) = (
        tolerate(
            view.oldProtocolVersion().call().await,
            result,
            &what("oldProtocolVersion"),
        ),
        tolerate(
            view.newProtocolVersion().call().await,
            result,
            &what("newProtocolVersion"),
        ),
        tolerate(
            view.fromRelease().call().await,
            result,
            &what("fromRelease"),
        ),
        tolerate(view.newRelease().call().await, result, &what("newRelease")),
        tolerate(
            view.oldProtocolVersionDeadline().call().await,
            result,
            &what("oldProtocolVersionDeadline"),
        ),
    )
    else {
        return Ok(None);
    };
    result.print_info(&format!(
        "  {label} {address}: {} -> {}, from release {from_release} to {new_release}, deadline {}",
        format_semver(old_version),
        format_semver(new_version),
        format_deadline(deadline)
    ));
    Ok(Some(TransitionFacts {
        address,
        old_version,
        new_version,
        from_release,
        new_release,
        deadline,
    }))
}

/// Reads the CTM state [`judge_replacement_state`] needs, or `None` when the CTM cannot answer
/// (already reported).
async fn read_replacement_facts<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    ctm: &CtmView::CtmViewInstance<&P>,
    expected: TransitionFacts,
    replacement: TransitionFacts,
    deadline_change: Option<DeadlineChange>,
) -> anyhow::Result<Option<ReplacementFacts>> {
    let (Some(ctm_version), Some(current_release), Some(committed)) = (
        tolerate(
            ctm.protocolVersion().call().await,
            result,
            "the CTM's protocolVersion()",
        ),
        tolerate(
            ctm.currentRelease().call().await,
            result,
            "the CTM's currentRelease()",
        ),
        tolerate(
            ctm.upgradeTransition(expected.old_version).call().await,
            result,
            "the CTM's upgradeTransition(departure)",
        ),
    ) else {
        return Ok(None);
    };
    let onward = if replacement.new_version < ctm_version {
        tolerate(
            ctm.upgradeTransition(replacement.new_version).call().await,
            result,
            "the CTM's upgradeTransition(target)",
        )
    } else {
        None
    };
    let onward = match onward {
        Some(onward) if !onward.is_zero() => {
            let source = tolerate(
                CTMTransitionView::new(onward, provider)
                    .fromRelease()
                    .call()
                    .await,
                result,
                "the onward edge's fromRelease()",
            );
            Some((onward, source))
        }
        Some(onward) => Some((onward, None)),
        None => None,
    };
    let effective_deadline = tolerate(
        ctm.protocolVersionDeadline(expected.old_version)
            .call()
            .await,
        result,
        "the CTM's protocolVersionDeadline(departure)",
    );
    Ok(Some(ReplacementFacts {
        ctm_version,
        current_release,
        expected,
        replacement,
        committed,
        onward,
        effective_deadline,
        deadline_change,
    }))
}

/// A reported packed version against the one the objects state; absent is a warning, like every
/// other summary field.
fn cross_check_version(
    result: &mut VerificationResult,
    field: &str,
    reported: Option<U256>,
    actual: U256,
) {
    match reported {
        Some(reported) if reported == actual => result.report_ok(&format!(
            "the package's reported {field} is {}",
            format_semver(actual)
        )),
        Some(reported) => result.report_error(&format!(
            "the package reports {field} {} but the objects state {}: the summary a reviewer \
             reads describes another replacement",
            format_semver(reported),
            format_semver(actual)
        )),
        None => result.report_warn(&format!(
            "the package does not report {field}, so {} is known only from the objects",
            format_semver(actual)
        )),
    }
}

fn format_deadline(deadline: U256) -> String {
    if deadline == U256::MAX {
        "none (type(uint256).max)".to_string()
    } else {
        deadline.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::registry::upgrade::judge_bytecode_publication;

    /// Exercise the replacement verifier's own shell call. The mocked RPC transport isolates
    /// the wiring: all unrelated findings are held fixed while real proxy logic changes.
    #[tokio::test]
    async fn replacement_verification_rejects_an_incompatible_system_proxy_shell() {
        use super::super::shell_path_tests::{
            ShellPathFixture, GOVERNANCE, NEW_RELEASE, TRANSITION,
        };
        use alloy::providers::ProviderBuilder;

        let mut outcomes = Vec::new();
        for change_logic in [false, true] {
            let fixture = ShellPathFixture::new(change_logic);
            fixture.replacement_reads();
            let provider = ProviderBuilder::new().connect_mocked_client(fixture.asserter.clone());
            let mut forward = recovered(0);
            forward.replacement = TRANSITION;
            let package = ReplacementPackage {
                reported_replaced: Some(forward.expected),
                reported_replacement: Some(TRANSITION),
                reported_ctm_transition: Some(TRANSITION),
                reported_release: Some(NEW_RELEASE),
                reported_ctm_executor: Some(forward.executor),
                reported_ctm: Some(forward.ctm),
                forward,
                ctm_key: "zksync_os".to_string(),
                reported_ctm_proxy_admin: None,
                calls: vec![the_forward()],
                external_actions: declared_forward(),
                create2_salts: Vec::new(),
                reported_old_version: None,
                reported_new_version: None,
                executor_records: Default::default(),
                member_records: Default::default(),
            };
            let mut result = VerificationResult::default();
            verify(
                &provider,
                &fixture.build,
                fixture.genesis.image.as_ref().ok(),
                &package,
                Some(GOVERNANCE),
                &[],
                &ReviewedEnv::default(),
                &mut result,
            )
            .await
            .unwrap();
            outcomes.push((result, fixture.asserter.read_q().is_empty()));
        }
        assert_eq!(
            outcomes[1].0.errors,
            outcomes[0].0.errors + 1,
            "the real replacement path must report the shell logic change as one additional error"
        );
        assert_eq!(outcomes[1].0.warnings, outcomes[0].0.warnings);
        assert!(outcomes[1].0.ensure_success().is_err());
        assert!(
            outcomes.iter().all(|(_, consumed)| *consumed),
            "both controls must reach the shell check"
        );
    }

    // A CTM at v0.36.0 on release R36, with v0.34.0 -> v0.35.0 (T34, R34 -> R35) and
    // v0.35.0 -> v0.36.0 (T35, R35 -> R36) committed. The replacement repairs T34.
    const V34: u64 = 0x22_0000_0000;
    const V35: u64 = 0x23_0000_0000;
    const V36: u64 = 0x24_0000_0000;
    const V37: u64 = 0x25_0000_0000;
    const R34: Address = Address::repeat_byte(0x34);
    const R35: Address = Address::repeat_byte(0x35);
    const R36: Address = Address::repeat_byte(0x36);
    const T34: Address = Address::repeat_byte(0xA4);
    const T35: Address = Address::repeat_byte(0xA5);
    const REPLACEMENT: Address = Address::repeat_byte(0xB4);
    const STRANGER: Address = Address::repeat_byte(0xEE);
    const DEADLINE: u64 = 1_800_000_000;

    fn v(packed: u64) -> U256 {
        U256::from(packed)
    }

    /// A replacement of T34 that lands where T34 did, below the CTM's version: valid.
    fn facts() -> ReplacementFacts {
        ReplacementFacts {
            ctm_version: v(V36),
            current_release: R36,
            expected: TransitionFacts {
                address: T34,
                old_version: v(V34),
                new_version: v(V35),
                from_release: R34,
                new_release: R35,
                deadline: v(DEADLINE),
            },
            replacement: TransitionFacts {
                address: REPLACEMENT,
                old_version: v(V34),
                new_version: v(V35),
                from_release: R34,
                new_release: R35,
                deadline: v(DEADLINE),
            },
            committed: T34,
            onward: Some((T35, Some(R35))),
            effective_deadline: Some(v(DEADLINE)),
            deadline_change: None,
        }
    }

    fn judge(facts: &ReplacementFacts) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_replacement_state(&mut result, facts);
        result
    }

    #[test]
    fn a_valid_replacement_onto_the_onward_edge_passes() {
        let result = judge(&facts());
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Skipping v0.35.0: landing at the CTM's version on its current release.
    #[test]
    fn a_valid_replacement_onto_the_current_release_passes() {
        let mut facts = facts();
        facts.replacement.new_version = v(V36);
        facts.replacement.new_release = R36;
        facts.onward = None;
        let result = judge(&facts);
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Compare-and-replace: the expected transition was already replaced (or never committed).
    #[test]
    fn a_stale_expected_transition_fails() {
        let mut facts = facts();
        facts.committed = STRANGER;
        assert_eq!(judge(&facts).errors, 1);
        facts.committed = Address::ZERO;
        assert_eq!(judge(&facts).errors, 1);
    }

    /// The error names the CTM's own refusal, so the report says which on-chain check it predicts.
    fn assert_refused_with(result: &VerificationResult, error: &str) {
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error(error), "{:?}", result.error_messages);
    }

    #[test]
    fn a_replacement_identical_to_the_expected_fails() {
        let mut facts = facts();
        facts.replacement.address = T34;
        assert_refused_with(&judge(&facts), "UpgradeTransitionUnchanged");
    }

    /// The source is the replaced transition's release, NOT the CTM's current release: a
    /// replacement departing from `currentRelease` is refused.
    #[test]
    fn a_replacement_from_another_source_release_fails() {
        let mut facts = facts();
        facts.replacement.from_release = facts.current_release;
        assert_eq!(judge(&facts).errors, 1);
    }

    #[test]
    fn a_replacement_pinning_another_deadline_fails() {
        let mut facts = facts();
        facts.replacement.deadline = v(DEADLINE + 1);
        assert_refused_with(&judge(&facts), "TransitionDeadlineMismatch");
    }

    /// Lower than what it replaces, even onto a release a chain could continue from.
    #[test]
    fn a_replacement_landing_earlier_fails() {
        let mut facts = facts();
        facts.replacement.new_version = v(V34 + 1);
        facts.replacement.new_release = Address::repeat_byte(0x3F);
        facts.onward = Some((Address::repeat_byte(0xAF), Some(Address::repeat_byte(0x3F))));
        assert_refused_with(&judge(&facts), "ProtocolVersionTooSmall");
    }

    /// Landing on a release the onward edge does not depart from: chains would be stranded.
    #[test]
    fn a_disconnected_destination_fails() {
        let mut facts = facts();
        facts.replacement.new_release = STRANGER;
        assert_eq!(judge(&facts).errors, 1);

        // Nothing committed onward from the target at all.
        let mut facts = self::facts();
        facts.onward = Some((Address::ZERO, None));
        assert_eq!(judge(&facts).errors, 1);

        // At the CTM's version, but not on its current release.
        let mut facts = self::facts();
        facts.replacement.new_version = v(V36);
        facts.replacement.new_release = STRANGER;
        facts.onward = None;
        assert_eq!(judge(&facts).errors, 1);
    }

    #[test]
    fn a_replacement_beyond_the_ctm_version_fails() {
        let mut facts = facts();
        facts.replacement.new_version = v(V37);
        facts.onward = None;
        assert_eq!(judge(&facts).errors, 1);
    }

    /// A departure at the CTM's version is not a commitment at all: nothing departs it yet.
    #[test]
    fn a_departure_not_below_the_ctm_version_fails() {
        let mut facts = facts();
        facts.ctm_version = v(V34);
        let result = judge(&facts);
        assert_eq!(
            result.errors, 2,
            "the departure is not below the CTM, and the target lies beyond it"
        );
    }

    /// A deadline change riding the forward is reported; one for another version is an error.
    #[test]
    fn a_deadline_change_must_be_for_the_departure() {
        let mut facts = facts();
        facts.deadline_change = Some(DeadlineChange {
            protocol_version: v(V34),
            timestamp: v(DEADLINE + 100),
        });
        assert_eq!(judge(&facts).errors, 0);
        facts.deadline_change = Some(DeadlineChange {
            protocol_version: v(V34),
            timestamp: U256::ZERO,
        });
        assert_eq!(judge(&facts).errors, 0);
        facts.deadline_change = Some(DeadlineChange {
            protocol_version: v(V35),
            timestamp: v(DEADLINE + 100),
        });
        assert_eq!(judge(&facts).errors, 1);
    }

    #[test]
    fn unpublished_replacement_bytecodes_fail() {
        let supplier = Address::repeat_byte(0x5B);
        let published = (B256::repeat_byte(0x01), Some(v(17)));
        let unpublished = (B256::repeat_byte(0x02), Some(U256::ZERO));
        let mut result = VerificationResult::default();
        let required_by = "`ChainTypeManager.replaceUpgradeTransition`";
        judge_bytecode_publication(
            &mut result,
            supplier,
            &[published, unpublished],
            required_by,
        );
        assert_eq!(result.errors, 1);
        assert!(result.has_error("`ChainTypeManager.replaceUpgradeTransition` refuses it"));
        let mut result = VerificationResult::default();
        judge_bytecode_publication(
            &mut result,
            supplier,
            &[published, (B256::ZERO, None)],
            required_by,
        );
        assert_eq!(
            result.errors, 0,
            "an unreadable block was reported when read"
        );
    }

    // ───────────────────────── the calldata ─────────────────────────

    const CTM: Address = Address::repeat_byte(0xC7);
    const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);

    fn recovered(index: usize) -> RecoveredReplacement {
        RecoveredReplacement {
            index,
            executor: CTM_EXECUTOR,
            ctm: CTM,
            expected: T34,
            replacement: REPLACEMENT,
            deadline: None,
        }
    }

    /// Stands in for the forward: the verdict locates it by position, its bytes are irrelevant.
    fn the_forward() -> GovernanceCall {
        GovernanceCall {
            target: CTM_EXECUTOR,
            value: U256::ZERO,
            data: vec![0x01, 0x02, 0x03, 0x04],
        }
    }

    fn other(target: Address) -> GovernanceCall {
        GovernanceCall {
            target,
            value: U256::ZERO,
            data: vec![0xde, 0xad, 0xbe, 0xef],
        }
    }

    fn judge_calls(
        forward: &RecoveredReplacement,
        calls: Vec<GovernanceCall>,
        declared: &[ExternalAction],
        ctm_owner: Option<Address>,
    ) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_replacement_calls(&mut result, forward, &calls, declared, ctm_owner);
        result
    }

    fn declared_forward() -> Vec<ExternalAction> {
        vec![ExternalAction::governance(
            "replace the committed transition",
            "CTM executor owner (governance)",
            &the_forward(),
        )]
    }

    #[test]
    fn the_single_forward_through_the_ctms_executor_passes() {
        let result = judge_calls(
            &recovered(0),
            vec![the_forward()],
            &declared_forward(),
            Some(CTM_EXECUTOR),
        );
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// The forward targets something that does not own the CTM: not the CTM's executor.
    #[test]
    fn a_forward_to_a_non_executor_fails() {
        let result = judge_calls(
            &recovered(0),
            vec![the_forward()],
            &declared_forward(),
            Some(STRANGER),
        );
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn an_extra_undeclared_call_fails() {
        let result = judge_calls(
            &recovered(0),
            vec![the_forward(), other(STRANGER)],
            &declared_forward(),
            Some(CTM_EXECUTOR),
        );
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_declared_call_outside_the_ctm_domain_rides_along() {
        let mut declared = declared_forward();
        declared.push(ExternalAction::governance(
            "an unrelated wiring",
            "governance",
            &other(STRANGER),
        ));
        let result = judge_calls(
            &recovered(1),
            vec![other(STRANGER), the_forward()],
            &declared,
            Some(CTM_EXECUTOR),
        );
        assert_eq!(result.errors, 0);
    }

    /// An `admin` declaration rides no governance bundle, so it does not excuse a bundle call.
    #[test]
    fn an_admin_declaration_does_not_account_for_a_bundle_call() {
        let mut declared = declared_forward();
        let mut wiring =
            ExternalAction::governance("an unrelated wiring", "governance", &other(STRANGER));
        wiring.phase = "admin".to_string();
        declared.push(wiring);
        let result = judge_calls(
            &recovered(0),
            vec![the_forward(), other(STRANGER)],
            &declared,
            Some(CTM_EXECUTOR),
        );
        assert_eq!(result.errors, 1);
    }

    /// A second call to the executor or the CTM is authority the review never saw — declaring it
    /// does not launder it.
    #[test]
    fn a_declared_extra_call_into_the_ctm_domain_fails() {
        for target in [CTM_EXECUTOR, CTM] {
            let mut declared = declared_forward();
            declared.push(ExternalAction::governance(
                "extra",
                "governance",
                &other(target),
            ));
            let result = judge_calls(
                &recovered(0),
                vec![the_forward(), other(target)],
                &declared,
                Some(CTM_EXECUTOR),
            );
            assert_eq!(result.errors, 1, "an extra call to {target} must fail");
        }
    }
}
