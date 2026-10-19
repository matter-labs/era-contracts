//! The lifecycle objects a package names — the two domain executors, `CoreUpgradeExecutor` and
//! `CTMUpgradeExecutor` — and the identity check that covers their bindings, plus the live owner
//! checks construction cannot cover.
//!
//! Both set their bindings as constructor immutables, which a runtime comparison
//! ([`super::provenance`]) masks. What identifies each is its CONSTRUCTION
//! ([`super::construction`]): the reviewed creation code run on its constructor arguments must
//! land at its address, which covers the immutable values too. Nothing is taken from the object's
//! own answers: a genuine executor built for an attacker's owner answers every getter like the
//! reviewed one. The getters ARE read, but only to name in the report which argument a failed
//! derivation disagrees on.
//!
//! An executor's arguments come from its EXECUTOR RECORD ([`super::records`]) — the salt and
//! original arguments the run that deployed it wrote down — and an executor without one is
//! unverified. The recorded immutable bindings (the CTM, the ProxyAdmins) are held against the
//! reviewed package values; the initial owner is only reported, since it may legitimately differ
//! from today's (a fresh ecosystem constructs for its deployer and nominates governance).
//!
//! What construction does not cover is the storage that moves afterwards — an executor's current
//! `owner()` and `pendingOwner()`. [`verify_executor_owners`] holds those against the reviewed
//! governance.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256};
use alloy::providers::Provider;

use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{constructor_args, expect_canonical_construction, ReviewedBuild};
use super::provenance::{expect_code_present, tolerate};
use super::views::{CTMUpgradeExecutorView, CoreUpgradeExecutorView, Ownable2StepView};

/// The executors a package drives, their records, and the reviewed values their recorded
/// bindings are held against. An executor the package does not drive is `None` and not verified.
///
/// An `Option` value marks one the review may lack (a package written before the prepare recorded
/// it, or no `--expected-governance-owner`); the check that needs it is then reported as
/// unverifiable — an ERROR — rather than run on a placeholder.
pub(super) struct LifecycleReview {
    /// The reviewed governance address: the live owner every executor must have, which a record's
    /// initial owner is reported against.
    pub(super) owner: Option<Address>,
    pub(super) core_executor: Option<CoreExecutorReview>,
    pub(super) ctm_executor: Option<CtmExecutorReview>,
    /// The executors' records, from the package and `--executor-record`.
    pub(super) records: UpgradeExecutorsRecord,
}

/// The core executor a package drives: the core leg's target, or the bootstrap manifest's
/// `coreExecutor`.
pub(super) struct CoreExecutorReview {
    pub(super) address: Address,
    /// The ecosystem `ProxyAdmin` it must have been built over (package `transparent_proxy_admin`).
    pub(super) proxy_admin: Option<Address>,
}

/// The CTM executor a package drives: the CTM legs' target, the bootstrap manifest's
/// `ctmExecutor`, or a replacement's `forward` target.
pub(super) struct CtmExecutorReview {
    pub(super) address: Address,
    /// The CTM it must have been built over — the independently reviewed intended CTM
    /// (`[ctms.*.state_transition] chain_type_manager_proxy`, or the bootstrap manifest's).
    pub(super) ctm: Option<Address>,
    /// The CTM-domain `ProxyAdmin` it must have been built over.
    pub(super) ctm_proxy_admin: Option<Address>,
}

/// The bindings as the executors themselves answer them, for the checks that follow (each
/// domain's rows are read through its executor's admin, the CTM state through its bound CTM).
/// Live values, so a run whose construction checks failed still reports against what would
/// actually execute.
#[derive(Default)]
pub(super) struct LifecycleBindings {
    pub(super) core_proxy_admin: Option<Address>,
    pub(super) ctm: Option<Address>,
    pub(super) ctm_proxy_admin: Option<Address>,
}

/// Verifies the construction of the executors in `review` from their records, recording each
/// verified one in `reviewed`.
///
/// Reads, in order: the core executor's code and `PROXY_ADMIN()`, then the CTM executor's code,
/// `CHAIN_TYPE_MANAGER()` and `CTM_PROXY_ADMIN()` — each only for an executor `review` names.
pub(super) async fn verify_lifecycle_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &LifecycleReview,
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<LifecycleBindings> {
    let mut bindings = LifecycleBindings::default();
    if review.owner.is_none() {
        result.report_error(
            "no reviewed governance owner: the executors' live owner cannot be held against the \
             review. Pass --expected-governance-owner",
        );
    }
    if let Some(core) = &review.core_executor {
        bindings.core_proxy_admin =
            verify_core_executor_construction(provider, build, result, review, core, reviewed)
                .await?;
    }
    if let Some(ctm) = &review.ctm_executor {
        let (bound_ctm, bound_admin) =
            verify_ctm_executor_construction(provider, build, result, review, ctm, reviewed)
                .await?;
        bindings.ctm = bound_ctm;
        bindings.ctm_proxy_admin = bound_admin;
    }
    Ok(bindings)
}

/// The core executor's construction from its record; returns its live `PROXY_ADMIN()`.
async fn verify_core_executor_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &LifecycleReview,
    core: &CoreExecutorReview,
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<Option<Address>> {
    let label = "the core executor";
    if !expect_code_present(provider, result, label, core.address).await? {
        return Ok(None);
    }
    let bound_admin = tolerate(
        CoreUpgradeExecutorView::new(core.address, provider)
            .PROXY_ADMIN()
            .call()
            .await,
        result,
        "the core executor's PROXY_ADMIN",
    );
    binding_check(
        result,
        label,
        "PROXY_ADMIN",
        bound_admin,
        core.proxy_admin,
        "transparent_proxy_admin",
    );
    match &review.records.core_executor {
        Some(record) => construct_from_record(
            build,
            result,
            review.owner,
            Recorded {
                label,
                address: core.address,
                short_name: "CoreUpgradeExecutor",
                record_address: record.address,
                salt: record.create2_salt,
                initial_owner: record.initial_owner,
                args: constructor_args::core_upgrade_executor(
                    record.initial_owner,
                    record.proxy_admin,
                ),
                immutables: vec![RecordedImmutable {
                    name: "PROXY_ADMIN",
                    recorded: record.proxy_admin,
                    reviewed: core.proxy_admin,
                    source: "transparent_proxy_admin",
                }],
            },
            reviewed,
        ),
        None => result.report_error(&missing_record(label, core.address)),
    }
    Ok(bound_admin)
}

/// The CTM executor's construction from its record; returns its live `CHAIN_TYPE_MANAGER()` and
/// `CTM_PROXY_ADMIN()`.
async fn verify_ctm_executor_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &LifecycleReview,
    ctm: &CtmExecutorReview,
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<(Option<Address>, Option<Address>)> {
    let label = "the CTM executor";
    if !expect_code_present(provider, result, label, ctm.address).await? {
        return Ok((None, None));
    }
    let executor = CTMUpgradeExecutorView::new(ctm.address, provider);
    let bound_ctm = tolerate(
        executor.CHAIN_TYPE_MANAGER().call().await,
        result,
        "the CTM executor's CHAIN_TYPE_MANAGER",
    );
    binding_check(
        result,
        label,
        "CHAIN_TYPE_MANAGER",
        bound_ctm,
        ctm.ctm,
        "chain_type_manager_proxy",
    );
    let bound_admin = tolerate(
        executor.CTM_PROXY_ADMIN().call().await,
        result,
        "the CTM executor's CTM_PROXY_ADMIN",
    );
    binding_check(
        result,
        label,
        "CTM_PROXY_ADMIN",
        bound_admin,
        ctm.ctm_proxy_admin,
        "transparent_proxy_admin",
    );
    match &review.records.ctm_executor {
        Some(record) => construct_from_record(
            build,
            result,
            review.owner,
            Recorded {
                label,
                address: ctm.address,
                short_name: "CTMUpgradeExecutor",
                record_address: record.address,
                salt: record.create2_salt,
                initial_owner: record.initial_owner,
                args: constructor_args::ctm_upgrade_executor(
                    record.initial_owner,
                    record.chain_type_manager,
                    record.ctm_proxy_admin,
                ),
                immutables: vec![
                    RecordedImmutable {
                        name: "CHAIN_TYPE_MANAGER",
                        recorded: record.chain_type_manager,
                        reviewed: ctm.ctm,
                        source: "chain_type_manager_proxy",
                    },
                    RecordedImmutable {
                        name: "CTM_PROXY_ADMIN",
                        recorded: record.ctm_proxy_admin,
                        reviewed: ctm.ctm_proxy_admin,
                        source: "transparent_proxy_admin",
                    },
                ],
            },
            reviewed,
        ),
        None => result.report_error(&missing_record(label, ctm.address)),
    }
    Ok((bound_ctm, bound_admin))
}

/// The executors' LIVE `owner()` and `pendingOwner()`, which construction does not cover: every
/// executor in `executors` must be owned by `expected` (the reviewed governance, labelled
/// `expected_label` in the report) with no nomination outstanding — a nominee accepts after the
/// review and takes the domain with it. With no `expected` (already reported by
/// [`verify_lifecycle_construction`]) the executors must at least answer to one owner, which is
/// reported unverified.
///
/// Reads, per executor in order: `owner()`, then `pendingOwner()`.
pub(super) async fn verify_executor_owners<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    expected: Option<Address>,
    expected_label: &str,
    executors: &[(&str, Address)],
) {
    let mut owners: Vec<(&str, Address)> = Vec::new();
    for (label, executor) in executors {
        let view = Ownable2StepView::new(*executor, provider);
        let owner = tolerate(
            view.owner().call().await,
            result,
            &format!("{label}'s owner"),
        );
        let pending = tolerate(
            view.pendingOwner().call().await,
            result,
            &format!("{label}'s pending owner"),
        );
        expect_no_nomination(result, label, pending);
        let Some(owner) = owner else {
            continue;
        };
        match expected {
            Some(expected) if owner == expected => result.report_ok(&format!(
                "{label} is owned by {expected_label} ({expected})"
            )),
            Some(expected) => result.report_error(&format!(
                "{label} is owned by {owner}, not by {expected_label} ({expected}): this upgrade \
                 would be driven by someone other than the reviewed owner"
            )),
            None => owners.push((label, owner)),
        }
    }
    if expected.is_some() {
        return;
    }
    let Some((_, first)) = owners.first().copied() else {
        return;
    };
    if let Some((label, other)) = owners.iter().find(|(_, owner)| *owner != first) {
        result.report_error(&format!(
            "{label} is owned by {other}, but another executor of this upgrade by {first}: one \
             upgrade would answer to two owners"
        ));
    } else {
        result.report_warn(&format!(
            "no --expected-governance-owner supplied: the executors' owner {first} is reported \
             but unverified against the review"
        ));
    }
}

/// An executor's `pendingOwner()`: a nominee could accept after the review and take the domain
/// with it. An unreadable one (`None`) was reported when read.
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
             the domain this upgrade runs through"
        )),
        None => {}
    }
}

/// One executor's construction as its record states it.
struct Recorded<'a> {
    label: &'a str,
    /// The executor being verified.
    address: Address,
    short_name: &'a str,
    /// The address the record itself names.
    record_address: Address,
    salt: B256,
    initial_owner: Address,
    /// The constructor arguments, built from the RECORDED values.
    args: Vec<u8>,
    immutables: Vec<RecordedImmutable<'a>>,
}

/// A constructor immutable as the record states it, and the reviewed value it must equal.
struct RecordedImmutable<'a> {
    name: &'a str,
    recorded: Address,
    reviewed: Option<Address>,
    /// The package field the reviewed value comes from.
    source: &'a str,
}

/// Re-derives an executor from its record under the recorded salt, holding each recorded immutable
/// against the review. The executor counts as reviewed only when the record names it, every
/// immutable is the reviewed one and the derivation lands at its address.
fn construct_from_record(
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    reviewed_owner: Option<Address>,
    recorded: Recorded<'_>,
    reviewed: &mut BTreeMap<Address, String>,
) {
    let Recorded {
        label,
        address,
        short_name,
        record_address,
        salt,
        initial_owner,
        args,
        immutables,
    } = recorded;
    if record_address != address {
        result.report_error(&format!(
            "{label} at {address}: its executor record names {record_address}, another object — \
             it says nothing about this one, so this executor's construction is unverified"
        ));
        return;
    }

    let mut bindings_reviewed = true;
    for immutable in &immutables {
        if immutable.recorded.is_zero() {
            bindings_reviewed = false;
            result.report_error(&format!(
                "{label}: its record says it was built over a zero {}, which its constructor \
                 refuses: the record does not describe the deployed executor",
                immutable.name
            ));
            continue;
        }
        match immutable.reviewed {
            Some(reviewed) if reviewed == immutable.recorded => result.report_ok(&format!(
                "{label}: its recorded {} is the reviewed {reviewed}",
                immutable.name
            )),
            Some(reviewed) => {
                bindings_reviewed = false;
                result.report_error(&format!(
                    "{label}: its record says it was built over {} {}, but the review fixes {reviewed} \
                     ({}): the executor is bound to something other than what the package names",
                    immutable.name, immutable.recorded, immutable.source
                ));
            }
            None => {
                bindings_reviewed = false;
                result.report_error(&format!(
                    "{label}: its record says it was built over {} {}, but the package does not name \
                     `{}`, so that binding is held against nothing the review fixes",
                    immutable.name, immutable.recorded, immutable.source
                ));
            }
        }
    }

    match reviewed_owner {
        Some(owner) if owner == initial_owner => result.report_ok(&format!(
            "{label} was constructed for the reviewed governance {owner}"
        )),
        Some(owner) => result.print_info(&format!(
            "  {label} was constructed for {initial_owner}, not the reviewed governance {owner}: \
             a fresh deployment constructs for its deployer and nominates governance, so this is \
             expected there — the live owner is checked separately"
        )),
        None => result.print_info(&format!("  {label} was constructed for {initial_owner}")),
    }

    if expect_canonical_construction(build, result, label, address, short_name, &args, &[salt])
        && bindings_reviewed
    {
        reviewed.insert(address, label.to_string());
    }
}

/// The error for an executor the review holds no record of.
fn missing_record(label: &str, address: Address) -> String {
    format!(
        "{label} at {address} has no executor record, so its construction cannot be re-derived \
         and it is unverified. Pass --executor-record with the output of the run that deployed \
         it: the `ecosystem init` / `ctm init` forge output, or the bootstrap package, which \
         carries its own"
    )
}

/// One immutable as the object answers it, against the reviewed value the construction uses.
///
/// Diagnostic only — the construction check is what decides — except for a zero binding, which
/// is an error here before the comparison. A reviewed value the package lacks is not compared
/// (the construction then reports itself unverifiable); an unreadable answer was already reported
/// by `tolerate`.
fn binding_check(
    result: &mut VerificationResult,
    label: &str,
    name: &str,
    live: Option<Address>,
    reviewed: Option<Address>,
    source: &str,
) {
    if live.is_some_and(|live| live.is_zero()) {
        result.report_error(&format!(
            "{label}: {name} is the zero address: the executor is bound to nothing"
        ));
        return;
    }
    match (live, reviewed) {
        (Some(live), Some(reviewed)) if live == reviewed => {
            result.report_ok(&format!("{label}: {name} is the reviewed {live}"));
        }
        (Some(live), Some(reviewed)) => result.report_error(&format!(
            "{label}: {name} is {live} but the review fixes {reviewed} ({source}): the object was \
             not built over the reviewed value, so its construction below cannot establish it"
        )),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::Bytes;
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    use super::super::construction::canonical_create2_address;

    const SALT: B256 = B256::repeat_byte(0x5A);
    const OWNER: Address = Address::repeat_byte(0x01);
    const ATTACKER: Address = Address::repeat_byte(0xBA);
    const CTM: Address = Address::repeat_byte(0x02);
    const CTM_ADMIN: Address = Address::repeat_byte(0x03);
    const ECO_ADMIN: Address = Address::repeat_byte(0x04);

    fn code(name: &str) -> Vec<u8> {
        format!("reviewed creation code of {name}").into_bytes()
    }

    fn build() -> ReviewedBuild {
        ReviewedBuild::from_parts(&[
            (
                "CoreUpgradeExecutor.sol",
                "CoreUpgradeExecutor",
                code("CoreUpgradeExecutor"),
            ),
            (
                "CTMUpgradeExecutor.sol",
                "CTMUpgradeExecutor",
                code("CTMUpgradeExecutor"),
            ),
        ])
    }

    /// A pair deployed the way the deploy scripts deploy them: the core executor over the
    /// ecosystem admin, the CTM executor over the CTM and its admin — both for `owner`, both under
    /// one salt.
    #[derive(Clone, Copy)]
    struct Pair {
        core_executor: Address,
        ctm_executor: Address,
    }

    fn genuine_pair(owner: Address) -> Pair {
        pair_built(owner, SALT)
    }

    fn pair_built(owner: Address, salt: B256) -> Pair {
        Pair {
            core_executor: canonical_create2_address(
                salt,
                &code("CoreUpgradeExecutor"),
                &constructor_args::core_upgrade_executor(owner, ECO_ADMIN),
            ),
            ctm_executor: canonical_create2_address(
                salt,
                &code("CTMUpgradeExecutor"),
                &constructor_args::ctm_upgrade_executor(owner, CTM, CTM_ADMIN),
            ),
        }
    }

    /// The answers the two executors give, in the order `verify_lifecycle_construction` reads
    /// them. Both have code and answer their getters with the bindings the genuine pair was built
    /// over — which is exactly what a counterfeit would answer too.
    fn queue_pair_answers(asserter: &Asserter) {
        let some_code = Bytes::from_static(&[0x60, 0x00]);
        // the core executor
        asserter.push_success(&some_code);
        asserter.push_success(&Bytes::from(ECO_ADMIN.abi_encode()));
        // the CTM executor
        asserter.push_success(&some_code);
        asserter.push_success(&Bytes::from(CTM.abi_encode()));
        asserter.push_success(&Bytes::from(CTM_ADMIN.abi_encode()));
    }

    /// The review of `pair`'s bindings, holding no executor records.
    fn review(owner: Option<Address>, pair: &Pair) -> LifecycleReview {
        LifecycleReview {
            owner,
            core_executor: Some(CoreExecutorReview {
                address: pair.core_executor,
                proxy_admin: Some(ECO_ADMIN),
            }),
            ctm_executor: Some(CtmExecutorReview {
                address: pair.ctm_executor,
                ctm: Some(CTM),
                ctm_proxy_admin: Some(CTM_ADMIN),
            }),
            records: Default::default(),
        }
    }

    async fn run(review: &LifecycleReview) -> (VerificationResult, usize) {
        let (result, reviewed) = run_reviewed(review).await;
        (result, reviewed.len())
    }

    async fn run_reviewed(
        review: &LifecycleReview,
    ) -> (VerificationResult, BTreeMap<Address, String>) {
        let asserter = Asserter::new();
        queue_pair_answers(&asserter);
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        let bindings =
            verify_lifecycle_construction(&provider, &build(), &mut result, review, &mut reviewed)
                .await
                .expect("a mocked read is not a transport failure");
        assert_eq!(bindings.core_proxy_admin, Some(ECO_ADMIN));
        assert_eq!(bindings.ctm, Some(CTM));
        assert_eq!(bindings.ctm_proxy_admin, Some(CTM_ADMIN));
        assert!(
            asserter.read_q().is_empty(),
            "every queued answer must have been consumed, or the read order drifted"
        );
        (result, reviewed)
    }

    /// A genuine pair, deployed by the reviewed constructors over the reviewed bindings and
    /// recorded by the run that deployed it, verifies clean. Their runtime code hashes to no
    /// artifact (immutables are patched in), so construction is the only identity they get.
    #[tokio::test]
    async fn a_genuine_pair_verifies_clean() {
        let pair = genuine_pair(OWNER);
        let recorded = LifecycleReview {
            records: records_of(&pair, OWNER, SALT),
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(result.errors, 0, "a genuine deployment must verify");
        assert_eq!(result.warnings, 0);
        assert_eq!(reviewed, 2, "both executors are established as reviewed");
    }

    /// THE finding: a counterfeit answering every getter with the reviewed bindings and carrying
    /// a record that states them is rejected, because it does not sit where the reviewed creation
    /// code lands for those values.
    #[tokio::test]
    async fn a_counterfeit_answering_the_reviewed_bindings_is_rejected() {
        let genuine = genuine_pair(OWNER);
        let counterfeit = Pair {
            ctm_executor: Address::repeat_byte(0xC0),
            ..genuine
        };
        let mut records = records_of(&genuine, OWNER, SALT);
        records.ctm_executor.as_mut().unwrap().address = counterfeit.ctm_executor;
        let review = LifecycleReview {
            records,
            ..review(Some(OWNER), &counterfeit)
        };
        let (result, reviewed) = run_reviewed(&review).await;
        assert_eq!(result.errors, 1, "the counterfeit CTM executor must fail");
        assert!(result.ensure_success().is_err());
        assert!(!reviewed.contains_key(&counterfeit.ctm_executor));
        assert_eq!(
            reviewed.len(),
            1,
            "the executor nothing substituted is established"
        );
    }

    /// A GENUINE pair built for an attacker's owner answers the same bindings and is just as
    /// canonically constructed — for the attacker. A record claiming the REVIEWED owner for it
    /// does not re-derive, which is why the owner never comes from the object's own `owner()`. Its
    /// true record does: a record's initial owner is only reported (a fresh ecosystem constructs
    /// for its deployer), and whoever owns the pair NOW is held against the review by
    /// [`verify_executor_owners`], not here.
    #[tokio::test]
    async fn a_pair_built_for_another_owner_rederives_only_from_its_true_record() {
        let pair = genuine_pair(ATTACKER);
        let claiming_the_reviewed_owner = LifecycleReview {
            records: records_of(&pair, OWNER, SALT),
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&claiming_the_reviewed_owner).await;
        assert_eq!(
            result.errors, 2,
            "neither executor was built for the reviewed owner"
        );
        assert_eq!(reviewed, 0);

        let true_record = LifecycleReview {
            records: records_of(&pair, ATTACKER, SALT),
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&true_record).await;
        assert_eq!(
            result.errors, 0,
            "the initial owner is reported, not judged"
        );
        assert_eq!(result.warnings, 0);
        assert_eq!(reviewed, 2);
    }

    /// No reviewed owner and no records is not a pass with a caveat: the missing owner and every
    /// executor without a record each say so as an error.
    #[tokio::test]
    async fn no_reviewed_owner_and_no_records_fail_every_executor() {
        let pair = genuine_pair(OWNER);
        let (result, reviewed) = run(&review(None, &pair)).await;
        assert_eq!(
            result.errors, 3,
            "one for the missing owner, one per executor without a record"
        );
        assert_eq!(reviewed, 0);
        assert!(result.ensure_success().is_err());
    }

    /// An executor without a record is unverified — an error naming the flag that supplies one —
    /// and is not established as reviewed, while the executor that has one still is.
    #[tokio::test]
    async fn a_missing_record_leaves_that_executor_unverified() {
        let pair = genuine_pair(OWNER);
        let all = || records_of(&pair, OWNER, SALT);
        let mut without_core_executor = all();
        without_core_executor.core_executor = None;
        let mut without_ctm_executor = all();
        without_ctm_executor.ctm_executor = None;
        for (records, missing) in [
            (without_core_executor, pair.core_executor),
            (without_ctm_executor, pair.ctm_executor),
        ] {
            let partial = LifecycleReview {
                records,
                ..review(Some(OWNER), &pair)
            };
            let (result, reviewed) = run_reviewed(&partial).await;
            assert_eq!(result.errors, 1, "{missing}");
            assert_eq!(result.warnings, 0, "{missing}");
            assert_eq!(reviewed.len(), 1, "{missing}");
            assert!(!reviewed.contains_key(&missing), "{missing}");
        }

        let message = missing_record("the CTM executor", pair.ctm_executor);
        assert!(message.contains("--executor-record"), "{message}");
        assert!(
            message.contains(&pair.ctm_executor.to_string()),
            "{message}"
        );
    }

    /// An executor the package does not drive is neither read nor verified: a core-only upgrade
    /// reviews no CTM executor, and a replacement no core executor.
    #[tokio::test]
    async fn an_executor_the_package_does_not_drive_is_not_read() {
        let pair = genuine_pair(OWNER);
        let mut core_only = LifecycleReview {
            records: records_of(&pair, OWNER, SALT),
            ..review(Some(OWNER), &pair)
        };
        core_only.ctm_executor = None;
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(&[0x60, 0x00]));
        asserter.push_success(&Bytes::from(ECO_ADMIN.abi_encode()));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        let bindings = verify_lifecycle_construction(
            &provider,
            &build(),
            &mut result,
            &core_only,
            &mut reviewed,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty());
        assert_eq!(result.errors, 0);
        assert_eq!(bindings.ctm, None);
        assert_eq!(reviewed.len(), 1);
        assert!(reviewed.contains_key(&pair.core_executor));
    }

    // ───────────────────────── executor records ─────────────────────────

    const DEPLOYER: Address = Address::repeat_byte(0xD1);
    /// Distinct from the genuine pair's `SALT`: the lifecycle check takes no reviewed salts, so an
    /// executor is re-derived under its record's alone.
    const RECORD_SALT: B256 = B256::repeat_byte(0x6E);

    /// What the run that deployed `pair` for `initial_owner` under `salt` records.
    fn records_of(pair: &Pair, initial_owner: Address, salt: B256) -> UpgradeExecutorsRecord {
        use crate::common::forge::scripts::upgrade_executors::{
            CoreExecutorRecord, CtmExecutorRecord,
        };
        UpgradeExecutorsRecord {
            core_executor: Some(CoreExecutorRecord {
                address: pair.core_executor,
                create2_salt: salt,
                initial_owner,
                proxy_admin: ECO_ADMIN,
            }),
            ctm_executor: Some(CtmExecutorRecord {
                address: pair.ctm_executor,
                create2_salt: salt,
                initial_owner,
                chain_type_manager: CTM,
                ctm_proxy_admin: CTM_ADMIN,
            }),
        }
    }

    /// THE case records exist for: a fresh ecosystem's executors, constructed for the deployer
    /// and handed to governance afterwards. A record restating today's owner re-derives neither;
    /// the record of the run that deployed them re-derives both.
    #[tokio::test]
    async fn a_moved_executor_verifies_from_its_record_and_not_from_the_current_values() {
        let pair = pair_built(DEPLOYER, RECORD_SALT);
        let current_values = LifecycleReview {
            records: records_of(&pair, OWNER, RECORD_SALT),
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&current_values).await;
        assert_eq!(result.errors, 2, "no executor was built for today's owner");
        assert_eq!(reviewed, 0);

        let recorded = LifecycleReview {
            records: records_of(&pair, DEPLOYER, RECORD_SALT),
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(result.errors, 0, "the record re-derives both");
        assert_eq!(result.warnings, 0);
        assert_eq!(reviewed, 2);
    }

    /// With a record the owner is no longer needed to re-derive, but the review still cannot hold
    /// the live owner against anything: that alone stays an error.
    #[tokio::test]
    async fn a_record_does_not_excuse_a_missing_reviewed_owner() {
        let pair = pair_built(DEPLOYER, RECORD_SALT);
        let recorded = LifecycleReview {
            records: records_of(&pair, DEPLOYER, RECORD_SALT),
            ..review(None, &pair)
        };
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 2);
    }

    /// A record whose values do not reproduce the executor's address — here, another initial
    /// owner — is not evidence for it.
    #[tokio::test]
    async fn a_record_whose_values_do_not_rederive_the_address_errors() {
        let pair = pair_built(DEPLOYER, RECORD_SALT);
        let mut records = records_of(&pair, DEPLOYER, RECORD_SALT);
        records.ctm_executor.as_mut().unwrap().initial_owner = ATTACKER;
        let recorded = LifecycleReview {
            records,
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 1, "only the CTM executor is left unverified");

        // The same for a wrong salt.
        let mut records = records_of(&pair, DEPLOYER, RECORD_SALT);
        records.core_executor.as_mut().unwrap().create2_salt = SALT;
        let recorded = LifecycleReview {
            records,
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 1);
    }

    /// A record of ANOTHER object says nothing about this one, even if it re-derives perfectly for
    /// the address it names.
    #[tokio::test]
    async fn a_record_naming_another_address_errors() {
        let pair = pair_built(DEPLOYER, RECORD_SALT);
        let other = pair_built(DEPLOYER, SALT);
        let mut records = records_of(&pair, DEPLOYER, RECORD_SALT);
        records.core_executor = records_of(&other, DEPLOYER, SALT).core_executor;
        let recorded = LifecycleReview {
            records,
            ..review(Some(OWNER), &pair)
        };
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 1);
    }

    /// The record proves what an executor was BUILT over; it is still held against what the
    /// package names. A genuine executor over another ProxyAdmin is the wrong executor, and one
    /// bound to another CTM than the reviewed intended one is too (design Q5: the target CTM must
    /// be the independently reviewed one, not whatever the executor answers).
    #[tokio::test]
    async fn a_recorded_binding_the_review_does_not_fix_errors() {
        let pair = pair_built(DEPLOYER, RECORD_SALT);
        let mut recorded = LifecycleReview {
            records: records_of(&pair, DEPLOYER, RECORD_SALT),
            ..review(Some(OWNER), &pair)
        };
        recorded.ctm_executor.as_mut().unwrap().ctm_proxy_admin = None;
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(
            result.errors, 1,
            "the CTM-domain ProxyAdmin is held against nothing"
        );
        assert_eq!(reviewed, 1);

        let mut recorded = LifecycleReview {
            records: records_of(&pair, DEPLOYER, RECORD_SALT),
            ..review(Some(OWNER), &pair)
        };
        recorded.ctm_executor.as_mut().unwrap().ctm = Some(Address::repeat_byte(0x7C));
        let (result, reviewed) = run(&recorded).await;
        assert_eq!(
            result.errors, 2,
            "the live CHAIN_TYPE_MANAGER and the recorded one both disagree with the review"
        );
        assert_eq!(reviewed, 1);
    }

    /// The executor bound to another CTM-domain ProxyAdmin than the reviewed one: the live
    /// `CTM_PROXY_ADMIN` and the record both disagree, and the executor is not established.
    #[tokio::test]
    async fn a_ctm_executor_bound_to_another_admin_fails() {
        let pair = pair_built(DEPLOYER, RECORD_SALT);
        let mut recorded = LifecycleReview {
            records: records_of(&pair, DEPLOYER, RECORD_SALT),
            ..review(Some(OWNER), &pair)
        };
        recorded.ctm_executor.as_mut().unwrap().ctm_proxy_admin = Some(Address::repeat_byte(0x7D));
        let (result, reviewed) = run_reviewed(&recorded).await;
        assert_eq!(result.errors, 2);
        assert!(!reviewed.contains_key(&pair.ctm_executor));
    }

    /// A zero binding is an error here even where the reviewed value is zero too (a bootstrap
    /// manifest's): live and recorded alike, and the executor is not established. The executor
    /// constructors refuse one, so such an executor cannot be the deployed one.
    #[tokio::test]
    async fn a_zero_binding_fails_even_against_a_zero_review() {
        let ctm_executor = canonical_create2_address(
            RECORD_SALT,
            &code("CTMUpgradeExecutor"),
            &constructor_args::ctm_upgrade_executor(DEPLOYER, CTM, Address::ZERO),
        );
        let mut records = records_of(&genuine_pair(DEPLOYER), DEPLOYER, RECORD_SALT);
        records.core_executor = None;
        let record = records.ctm_executor.as_mut().unwrap();
        record.address = ctm_executor;
        record.create2_salt = RECORD_SALT;
        record.ctm_proxy_admin = Address::ZERO;
        let review = LifecycleReview {
            owner: Some(OWNER),
            core_executor: None,
            ctm_executor: Some(CtmExecutorReview {
                address: ctm_executor,
                ctm: Some(CTM),
                ctm_proxy_admin: Some(Address::ZERO),
            }),
            records,
        };
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(&[0x60, 0x00]));
        asserter.push_success(&Bytes::from(CTM.abi_encode()));
        asserter.push_success(&Bytes::from(Address::ZERO.abi_encode()));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        verify_lifecycle_construction(&provider, &build(), &mut result, &review, &mut reviewed)
            .await
            .unwrap();
        assert!(asserter.read_q().is_empty());
        assert_eq!(result.errors, 2, "{:?}", result.error_messages);
        assert!(result.has_error("CTM_PROXY_ADMIN is the zero address"));
        assert!(result.has_error("built over a zero CTM_PROXY_ADMIN"));
        assert!(reviewed.is_empty());
    }

    // ───────────────────────── live owners ─────────────────────────

    async fn owners(
        answers: &[(Address, Address)],
        expected: Option<Address>,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for (owner, pending) in answers {
            asserter.push_success(&Bytes::from(owner.abi_encode()));
            asserter.push_success(&Bytes::from(pending.abi_encode()));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let executors: Vec<(&str, Address)> = [
            ("the core executor", Address::repeat_byte(0xE0)),
            ("the CTM executor", Address::repeat_byte(0xE7)),
        ]
        .into_iter()
        .take(answers.len())
        .collect();
        verify_executor_owners(
            &provider,
            &mut result,
            expected,
            "the reviewed governance",
            &executors,
        )
        .await;
        assert!(asserter.read_q().is_empty());
        result
    }

    #[tokio::test]
    async fn executors_owned_by_the_reviewed_governance_pass() {
        let result = owners(
            &[(OWNER, Address::ZERO), (OWNER, Address::ZERO)],
            Some(OWNER),
        )
        .await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Both executors must be governed by the reviewed governance, with no nomination outstanding.
    #[tokio::test]
    async fn another_owner_or_a_nomination_fails() {
        let result = owners(
            &[(OWNER, Address::ZERO), (ATTACKER, Address::ZERO)],
            Some(OWNER),
        )
        .await;
        assert_eq!(result.errors, 1);

        let result = owners(&[(OWNER, ATTACKER), (OWNER, Address::ZERO)], Some(OWNER)).await;
        assert_eq!(result.errors, 1);
    }

    /// Without a reviewed owner the executors must at least agree; agreeing ones are a warning.
    #[tokio::test]
    async fn without_a_reviewed_owner_the_executors_must_agree() {
        let result = owners(&[(OWNER, Address::ZERO), (OWNER, Address::ZERO)], None).await;
        assert_eq!((result.errors, result.warnings), (0, 1));
        let result = owners(&[(OWNER, Address::ZERO), (ATTACKER, Address::ZERO)], None).await;
        assert_eq!((result.errors, result.warnings), (1, 0));
    }

    /// The current-owner half: an outstanding nomination fails the run, a cleared one passes, an
    /// unreadable one was reported when read.
    #[test]
    fn a_pending_nomination_on_an_executor_fails() {
        let mut result = VerificationResult::default();
        expect_no_nomination(&mut result, "the core executor", Some(Address::ZERO));
        assert_eq!((result.errors, result.warnings), (0, 0));
        expect_no_nomination(&mut result, "the core executor", None);
        assert_eq!((result.errors, result.warnings), (0, 0));
        expect_no_nomination(
            &mut result,
            "the CTM executor",
            Some(Address::repeat_byte(0xBA)),
        );
        assert_eq!(result.errors, 1);
    }
}
