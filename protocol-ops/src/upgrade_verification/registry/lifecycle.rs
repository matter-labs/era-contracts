//! The lifecycle objects a package names — the coordinator and the two domain executors — and the
//! identity check that covers their bindings.
//!
//! All three set their bindings as constructor immutables, which a runtime comparison
//! ([`super::provenance`]) masks. What identifies each is its CONSTRUCTION
//! ([`super::construction`]): the reviewed creation code run on its constructor arguments must
//! land at its address, which covers the immutable values too. Nothing is taken from the object's own answers: a genuine
//! executor built for an attacker's owner answers every getter like the reviewed one. The getters
//! ARE read, but only to name in the report which argument a failed derivation disagrees on.
//!
//! An executor's arguments come from its EXECUTOR RECORD ([`super::records`]) — the salt and
//! original arguments the run that deployed it wrote down — and an executor without one is
//! unverified. The recorded immutable bindings (the CTM, the ProxyAdmins, `CORE_EXECUTOR`) are
//! held against the reviewed package values; the initial owner and the CTM executor's
//! constructor coordinator are only reported, since both may legitimately differ from today's (a
//! fresh ecosystem constructs for its deployer and nominates governance).
//!
//! What construction does not cover is the storage that moves afterwards — an executor's current
//! `owner()`, `pendingOwner()` and `coordinator()`. Those are live checks the verifiers keep beside
//! the construction check, against the reviewed governance owner and coordinator.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256};
use alloy::providers::Provider;

use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{constructor_args, expect_canonical_construction, ReviewedBuild};
use super::provenance::{expect_code_present, tolerate};
use super::views::{CTMUpgradeExecutorView, CoreUpgradeExecutorView, EcosystemUpgradeExecutorView};

/// The three executors' records and the reviewed values their recorded bindings are held against.
///
/// An `Option` marks a value the review may lack (a package written before the prepare recorded
/// it, or no `--expected-governance-owner`); the check that needs it is then reported as
/// unverifiable — an ERROR — rather than run on a placeholder.
pub(super) struct LifecycleReview {
    /// The reviewed governance address: the live owner every executor must have, which a record's
    /// initial owner is reported against.
    pub(super) owner: Option<Address>,
    pub(super) coordinator: Address,
    /// The core executor the coordinator was built over: the bootstrap manifest's `coreExecutor`,
    /// or package `core_upgrade_executor_addr` for a recurring upgrade.
    pub(super) core_executor: Option<Address>,
    /// The ecosystem `ProxyAdmin` the core executor was built over (package
    /// `transparent_proxy_admin`).
    pub(super) core_proxy_admin: Option<Address>,
    pub(super) ctm_executor: Address,
    /// The CTM the CTM executor was built over.
    pub(super) ctm: Option<Address>,
    /// The CTM-domain `ProxyAdmin` the CTM executor was built over.
    pub(super) ctm_proxy_admin: Option<Address>,
    /// The executors' records, from the package and `--executor-record`.
    pub(super) records: UpgradeExecutorsRecord,
}

/// The bindings as the objects themselves answer them, for the checks that follow (the
/// ecosystem rows are read through the core executor's admin, the ecosystem leg through the
/// coordinator's core executor). Live values, so a run whose construction checks failed still
/// reports against what would actually execute.
#[derive(Default)]
pub(super) struct LifecycleBindings {
    pub(super) core_executor: Option<Address>,
    pub(super) core_proxy_admin: Option<Address>,
}

/// Verifies the construction of the coordinator, the core executor and the CTM executor from
/// their records in `review`, recording each verified object in `reviewed`.
///
/// Reads, in order: the coordinator's code and `CORE_EXECUTOR()`, the core executor's code and
/// `PROXY_ADMIN()`, the CTM executor's code, `CHAIN_TYPE_MANAGER()` and `CTM_PROXY_ADMIN()`.
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

    // ── the coordinator ──
    let label = "the coordinator";
    if expect_code_present(provider, result, label, review.coordinator).await? {
        let coordinator = EcosystemUpgradeExecutorView::new(review.coordinator, provider);
        let bound_core_executor = tolerate(
            coordinator.CORE_EXECUTOR().call().await,
            result,
            "the coordinator's CORE_EXECUTOR",
        );
        bindings.core_executor = bound_core_executor;
        binding_check(
            result,
            label,
            "CORE_EXECUTOR",
            bound_core_executor,
            review.core_executor,
            "core_upgrade_executor_addr",
        );
        match &review.records.coordinator {
            Some(record) => construct_from_record(
                build,
                result,
                review.owner,
                Recorded {
                    label,
                    address: review.coordinator,
                    short_name: "EcosystemUpgradeExecutor",
                    record_address: record.address,
                    salt: record.create2_salt,
                    initial_owner: record.initial_owner,
                    args: constructor_args::ecosystem_upgrade_executor(
                        record.initial_owner,
                        record.core_executor,
                    ),
                    immutables: vec![RecordedImmutable {
                        name: "CORE_EXECUTOR",
                        recorded: record.core_executor,
                        reviewed: review.core_executor,
                        source: "core_upgrade_executor_addr",
                    }],
                },
                reviewed,
            ),
            None => result.report_error(&missing_record(label, review.coordinator)),
        }
    }

    // ── the core executor ──
    let label = "the core executor";
    if let Some(core_executor_addr) = review.core_executor.or(bindings.core_executor) {
        if expect_code_present(provider, result, label, core_executor_addr).await? {
            let core_executor = CoreUpgradeExecutorView::new(core_executor_addr, provider);
            let bound_admin = tolerate(
                core_executor.PROXY_ADMIN().call().await,
                result,
                "the core executor's PROXY_ADMIN",
            );
            bindings.core_proxy_admin = bound_admin;
            binding_check(
                result,
                label,
                "PROXY_ADMIN",
                bound_admin,
                review.core_proxy_admin,
                "transparent_proxy_admin",
            );
            match &review.records.core_executor {
                Some(record) => construct_from_record(
                    build,
                    result,
                    review.owner,
                    Recorded {
                        label,
                        address: core_executor_addr,
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
                            reviewed: review.core_proxy_admin,
                            source: "transparent_proxy_admin",
                        }],
                    },
                    reviewed,
                ),
                None => result.report_error(&missing_record(label, core_executor_addr)),
            }
        }
    } else {
        result.report_error(
            "the core executor is unknown: the package does not name it and the coordinator's \
             CORE_EXECUTOR could not be read, so neither its construction nor the ecosystem leg \
             can be verified",
        );
    }

    // ── the CTM executor ──
    verify_ctm_executor_construction(provider, build, result, review, reviewed).await?;

    Ok(bindings)
}

/// Verifies the CTM executor's construction from its record in `review`, recording it in
/// `reviewed` when it re-derives.
///
/// Reads, in order: the executor's code, `CHAIN_TYPE_MANAGER()` and `CTM_PROXY_ADMIN()`.
async fn verify_ctm_executor_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &LifecycleReview,
    reviewed: &mut BTreeMap<Address, String>,
) -> anyhow::Result<()> {
    let label = "the CTM executor";
    if !expect_code_present(provider, result, label, review.ctm_executor).await? {
        return Ok(());
    }
    let ctm_executor = CTMUpgradeExecutorView::new(review.ctm_executor, provider);
    let bound_ctm = tolerate(
        ctm_executor.CHAIN_TYPE_MANAGER().call().await,
        result,
        "the CTM executor's CHAIN_TYPE_MANAGER",
    );
    binding_check(
        result,
        label,
        "CHAIN_TYPE_MANAGER",
        bound_ctm,
        review.ctm,
        "chain_type_manager_proxy",
    );
    let bound_admin = tolerate(
        ctm_executor.CTM_PROXY_ADMIN().call().await,
        result,
        "the CTM executor's CTM_PROXY_ADMIN",
    );
    binding_check(
        result,
        label,
        "CTM_PROXY_ADMIN",
        bound_admin,
        review.ctm_proxy_admin,
        "transparent_proxy_admin",
    );
    match &review.records.ctm_executor {
        Some(record) => {
            if record.coordinator == review.coordinator {
                result.report_ok(&format!(
                    "{label} was constructed with the reviewed coordinator {}",
                    review.coordinator
                ));
            } else {
                result.print_info(&format!(
                    "  {label} was constructed with coordinator {} and must have been re-pointed \
                     to the reviewed {} since (`setCoordinator`): its live coordinator is checked \
                     separately",
                    record.coordinator, review.coordinator
                ));
            }
            construct_from_record(
                build,
                result,
                review.owner,
                Recorded {
                    label,
                    address: review.ctm_executor,
                    short_name: "CTMUpgradeExecutor",
                    record_address: record.address,
                    salt: record.create2_salt,
                    initial_owner: record.initial_owner,
                    args: constructor_args::ctm_upgrade_executor(
                        record.initial_owner,
                        record.chain_type_manager,
                        record.ctm_proxy_admin,
                        record.coordinator,
                    ),
                    immutables: vec![
                        RecordedImmutable {
                            name: "CHAIN_TYPE_MANAGER",
                            recorded: record.chain_type_manager,
                            reviewed: review.ctm,
                            source: "chain_type_manager_proxy",
                        },
                        RecordedImmutable {
                            name: "CTM_PROXY_ADMIN",
                            recorded: record.ctm_proxy_admin,
                            reviewed: review.ctm_proxy_admin,
                            source: "transparent_proxy_admin",
                        },
                    ],
                },
                reviewed,
            );
        }
        None => result.report_error(&missing_record(label, review.ctm_executor)),
    }
    Ok(())
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
/// Diagnostic only — the construction check is what decides. A reviewed value the package lacks
/// is not compared (the construction then reports itself unverifiable); an unreadable answer
/// was already reported by `tolerate`.
fn binding_check<T: PartialEq + std::fmt::Display>(
    result: &mut VerificationResult,
    label: &str,
    name: &str,
    live: Option<T>,
    reviewed: Option<T>,
    source: &str,
) {
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
                "EcosystemUpgradeExecutor.sol",
                "EcosystemUpgradeExecutor",
                code("EcosystemUpgradeExecutor"),
            ),
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

    /// A trio deployed the way the v35 prepare deploys them: the core executor over the
    /// ecosystem admin, the coordinator over the core executor, the CTM executor answering to
    /// the coordinator — all for `owner`, all under one salt.
    struct Trio {
        coordinator: Address,
        core_executor: Address,
        ctm_executor: Address,
    }

    fn genuine_trio(owner: Address) -> Trio {
        trio_built(owner, SALT, None)
    }

    /// A trio built for `owner` under `salt`, its CTM executor constructed with
    /// `ctm_constructor_coordinator` (the trio's own coordinator when `None`).
    fn trio_built(
        owner: Address,
        salt: B256,
        ctm_constructor_coordinator: Option<Address>,
    ) -> Trio {
        let core_executor = canonical_create2_address(
            salt,
            &code("CoreUpgradeExecutor"),
            &constructor_args::core_upgrade_executor(owner, ECO_ADMIN),
        );
        let coordinator = canonical_create2_address(
            salt,
            &code("EcosystemUpgradeExecutor"),
            &constructor_args::ecosystem_upgrade_executor(owner, core_executor),
        );
        let ctm_executor = canonical_create2_address(
            salt,
            &code("CTMUpgradeExecutor"),
            &constructor_args::ctm_upgrade_executor(
                owner,
                CTM,
                CTM_ADMIN,
                ctm_constructor_coordinator.unwrap_or(coordinator),
            ),
        );
        Trio {
            coordinator,
            core_executor,
            ctm_executor,
        }
    }

    /// The answers the three objects give, in the order `verify_lifecycle_construction` reads
    /// them. Every object has code and answers its getters with the bindings the genuine trio
    /// was built over — which is exactly what a counterfeit would answer too.
    fn queue_trio_answers(asserter: &Asserter, trio: &Trio) {
        let some_code = Bytes::from_static(&[0x60, 0x00]);
        // the coordinator
        asserter.push_success(&some_code);
        asserter.push_success(&Bytes::from(trio.core_executor.abi_encode()));
        // the core executor
        asserter.push_success(&some_code);
        asserter.push_success(&Bytes::from(ECO_ADMIN.abi_encode()));
        // the CTM executor
        asserter.push_success(&some_code);
        asserter.push_success(&Bytes::from(CTM.abi_encode()));
        asserter.push_success(&Bytes::from(CTM_ADMIN.abi_encode()));
    }

    /// The review of `trio`'s bindings, holding no executor records.
    fn review(owner: Option<Address>, trio: &Trio) -> LifecycleReview {
        LifecycleReview {
            owner,
            coordinator: trio.coordinator,
            core_executor: Some(trio.core_executor),
            core_proxy_admin: Some(ECO_ADMIN),
            ctm_executor: trio.ctm_executor,
            ctm: Some(CTM),
            ctm_proxy_admin: Some(CTM_ADMIN),
            records: Default::default(),
        }
    }

    async fn run(trio: &Trio, review: &LifecycleReview) -> (VerificationResult, usize) {
        let (result, reviewed) = run_reviewed(trio, review).await;
        (result, reviewed.len())
    }

    async fn run_reviewed(
        trio: &Trio,
        review: &LifecycleReview,
    ) -> (VerificationResult, BTreeMap<Address, String>) {
        let asserter = Asserter::new();
        queue_trio_answers(&asserter, trio);
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let mut reviewed = BTreeMap::new();
        let bindings =
            verify_lifecycle_construction(&provider, &build(), &mut result, review, &mut reviewed)
                .await
                .expect("a mocked read is not a transport failure");
        assert_eq!(bindings.core_executor, Some(trio.core_executor));
        assert_eq!(bindings.core_proxy_admin, Some(ECO_ADMIN));
        assert!(
            asserter.read_q().is_empty(),
            "every queued answer must have been consumed, or the read order drifted"
        );
        (result, reviewed)
    }

    /// The regression the executors could never pass before: a genuine trio, deployed by the
    /// reviewed constructors over the reviewed bindings and recorded by the run that deployed it,
    /// verifies clean. Their runtime code hashes to no artifact (immutables are patched in), which
    /// the retired identity check reported as an error on every real deployment.
    #[tokio::test]
    async fn a_genuine_trio_verifies_clean() {
        let trio = genuine_trio(OWNER);
        let recorded = LifecycleReview {
            records: records_of(&trio, OWNER, SALT, trio.coordinator),
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(result.errors, 0, "a genuine deployment must verify");
        assert_eq!(result.warnings, 0);
        assert_eq!(
            reviewed, 3,
            "all three executors are established as reviewed"
        );
    }

    /// THE finding: a counterfeit answering every getter with the reviewed bindings — the exact
    /// answers the retired check accepted — and carrying a record that states them is rejected,
    /// because it does not sit where the reviewed creation code lands for those values.
    #[tokio::test]
    async fn a_counterfeit_answering_the_reviewed_bindings_is_rejected() {
        let genuine = genuine_trio(OWNER);
        let counterfeit = Trio {
            coordinator: Address::repeat_byte(0xC0),
            ..genuine
        };
        let mut records = records_of(&genuine, OWNER, SALT, genuine.coordinator);
        records.coordinator.as_mut().unwrap().address = counterfeit.coordinator;
        let mut review = LifecycleReview {
            records,
            ..review(Some(OWNER), &genuine)
        };
        review.coordinator = counterfeit.coordinator;
        let (result, reviewed) = run_reviewed(&counterfeit, &review).await;
        assert_eq!(result.errors, 1, "the counterfeit coordinator must fail");
        assert!(result.ensure_success().is_err());
        assert!(!reviewed.contains_key(&counterfeit.coordinator));
        assert_eq!(
            reviewed.len(),
            2,
            "the executors nothing substituted are established; that the CTM executor still \
             answers to the genuine coordinator is for the live `coordinator()` check to report"
        );
    }

    /// A GENUINE trio built for an attacker's owner answers the same bindings and is just as
    /// canonically constructed — for the attacker. A record claiming the REVIEWED owner for it does
    /// not re-derive, which is why the owner never comes from the object's own `owner()`. Its true
    /// record does: a record's initial owner is only reported (a fresh ecosystem constructs for its
    /// deployer), and whoever owns the trio NOW is held against the review by the live owner check
    /// (`operation::verify_governance_owner`), not here.
    #[tokio::test]
    async fn a_trio_built_for_another_owner_rederives_only_from_its_true_record() {
        let trio = genuine_trio(ATTACKER);
        let claiming_the_reviewed_owner = LifecycleReview {
            records: records_of(&trio, OWNER, SALT, trio.coordinator),
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &claiming_the_reviewed_owner).await;
        assert_eq!(
            result.errors, 3,
            "none of the three was built for the reviewed owner"
        );
        assert_eq!(reviewed, 0);

        let true_record = LifecycleReview {
            records: records_of(&trio, ATTACKER, SALT, trio.coordinator),
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &true_record).await;
        assert_eq!(
            result.errors, 0,
            "the initial owner is reported, not judged"
        );
        assert_eq!(result.warnings, 0);
        assert_eq!(reviewed, 3);
    }

    /// No reviewed owner and no records is not a pass with a caveat: the missing owner and every
    /// executor without a record each say so as an error.
    #[tokio::test]
    async fn no_reviewed_owner_and_no_records_fail_every_executor() {
        let trio = genuine_trio(OWNER);
        let (result, reviewed) = run(&trio, &review(None, &trio)).await;
        assert_eq!(
            result.errors, 4,
            "one for the missing owner, one per executor without a record"
        );
        assert_eq!(reviewed, 0);
        assert!(result.ensure_success().is_err());
    }

    /// An executor without a record is unverified — an error naming the flag that supplies one —
    /// and is not established as reviewed, while the executors that have one still are.
    #[tokio::test]
    async fn a_missing_record_leaves_that_executor_unverified() {
        let trio = genuine_trio(OWNER);
        let all = || records_of(&trio, OWNER, SALT, trio.coordinator);
        let mut without_coordinator = all();
        without_coordinator.coordinator = None;
        let mut without_core_executor = all();
        without_core_executor.core_executor = None;
        let mut without_ctm_executor = all();
        without_ctm_executor.ctm_executor = None;
        for (records, missing) in [
            (without_coordinator, trio.coordinator),
            (without_core_executor, trio.core_executor),
            (without_ctm_executor, trio.ctm_executor),
        ] {
            let partial = LifecycleReview {
                records,
                ..review(Some(OWNER), &trio)
            };
            let (result, reviewed) = run_reviewed(&trio, &partial).await;
            assert_eq!(result.errors, 1, "{missing}");
            assert_eq!(result.warnings, 0, "{missing}");
            assert_eq!(reviewed.len(), 2, "{missing}");
            assert!(!reviewed.contains_key(&missing), "{missing}");
        }

        let message = missing_record("the CTM executor", trio.ctm_executor);
        assert!(message.contains("--executor-record"), "{message}");
        assert!(
            message.contains(&trio.ctm_executor.to_string()),
            "{message}"
        );
    }

    // ───────────────────────── executor records ─────────────────────────

    const DEPLOYER: Address = Address::repeat_byte(0xD1);
    const FIRST_COORDINATOR: Address = Address::repeat_byte(0xC1);
    /// Distinct from the genuine trio's `SALT`: the lifecycle check takes no reviewed salts, so an
    /// executor is re-derived under its record's alone.
    const RECORD_SALT: B256 = B256::repeat_byte(0x6E);

    /// What the run that deployed `trio` for `initial_owner` under `salt` records, the CTM
    /// executor constructed with `ctm_constructor_coordinator`.
    fn records_of(
        trio: &Trio,
        initial_owner: Address,
        salt: B256,
        ctm_constructor_coordinator: Address,
    ) -> UpgradeExecutorsRecord {
        use crate::common::forge::scripts::upgrade_executors::{
            CoordinatorRecord, CoreExecutorRecord, CtmExecutorRecord,
        };
        UpgradeExecutorsRecord {
            core_executor: Some(CoreExecutorRecord {
                address: trio.core_executor,
                create2_salt: salt,
                initial_owner,
                proxy_admin: ECO_ADMIN,
            }),
            coordinator: Some(CoordinatorRecord {
                address: trio.coordinator,
                create2_salt: salt,
                initial_owner,
                core_executor: trio.core_executor,
            }),
            ctm_executor: Some(CtmExecutorRecord {
                address: trio.ctm_executor,
                create2_salt: salt,
                initial_owner,
                chain_type_manager: CTM,
                ctm_proxy_admin: CTM_ADMIN,
                coordinator: ctm_constructor_coordinator,
            }),
        }
    }

    /// THE case records exist for: a fresh ecosystem's executors, constructed for the deployer
    /// and handed to governance afterwards, the CTM executor since re-pointed from the coordinator
    /// it was built with. A record restating today's owner and coordinator re-derives none of the
    /// three; the record of the run that deployed them re-derives all three.
    #[tokio::test]
    async fn a_moved_executor_verifies_from_its_record_and_not_from_the_current_values() {
        let trio = trio_built(DEPLOYER, RECORD_SALT, Some(FIRST_COORDINATOR));
        let current_values = LifecycleReview {
            records: records_of(&trio, OWNER, RECORD_SALT, trio.coordinator),
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &current_values).await;
        assert_eq!(
            result.errors, 3,
            "no executor was built for today's owner and coordinator"
        );
        assert_eq!(reviewed, 0);

        let recorded = LifecycleReview {
            records: records_of(&trio, DEPLOYER, RECORD_SALT, FIRST_COORDINATOR),
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(result.errors, 0, "the record re-derives all three");
        assert_eq!(result.warnings, 0);
        assert_eq!(reviewed, 3);
    }

    /// With a record the owner is no longer needed to re-derive, but the review still cannot hold
    /// the live owner against anything: that alone stays an error.
    #[tokio::test]
    async fn a_record_does_not_excuse_a_missing_reviewed_owner() {
        let trio = trio_built(DEPLOYER, RECORD_SALT, None);
        let recorded = LifecycleReview {
            records: records_of(&trio, DEPLOYER, RECORD_SALT, trio.coordinator),
            ..review(None, &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 3);
    }

    /// A record whose values do not reproduce the executor's address — here, another initial
    /// owner — is not evidence for it.
    #[tokio::test]
    async fn a_record_whose_values_do_not_rederive_the_address_errors() {
        let trio = trio_built(DEPLOYER, RECORD_SALT, None);
        let mut records = records_of(&trio, DEPLOYER, RECORD_SALT, trio.coordinator);
        records.ctm_executor.as_mut().unwrap().initial_owner = ATTACKER;
        let recorded = LifecycleReview {
            records,
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 2, "only the CTM executor is left unverified");

        // The same for a wrong salt.
        let mut records = records_of(&trio, DEPLOYER, RECORD_SALT, trio.coordinator);
        records.core_executor.as_mut().unwrap().create2_salt = SALT;
        let recorded = LifecycleReview {
            records,
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 2);
    }

    /// A record of ANOTHER object says nothing about this one, even if it re-derives perfectly for
    /// the address it names.
    #[tokio::test]
    async fn a_record_naming_another_address_errors() {
        let trio = trio_built(DEPLOYER, RECORD_SALT, None);
        let other = trio_built(DEPLOYER, SALT, None);
        let mut records = records_of(&trio, DEPLOYER, RECORD_SALT, trio.coordinator);
        records.coordinator = records_of(&other, DEPLOYER, SALT, other.coordinator).coordinator;
        let recorded = LifecycleReview {
            records,
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(result.errors, 1);
        assert_eq!(reviewed, 2);
    }

    /// The record proves what an executor was BUILT over; it is still held against what the
    /// package names. A genuine executor over another ProxyAdmin is the wrong executor.
    #[tokio::test]
    async fn a_recorded_binding_the_review_does_not_fix_errors() {
        let trio = trio_built(DEPLOYER, RECORD_SALT, None);
        let recorded = LifecycleReview {
            records: records_of(&trio, DEPLOYER, RECORD_SALT, trio.coordinator),
            ctm_proxy_admin: None,
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(
            result.errors, 1,
            "the CTM-domain ProxyAdmin is held against nothing"
        );
        assert_eq!(reviewed, 2);

        let recorded = LifecycleReview {
            records: records_of(&trio, DEPLOYER, RECORD_SALT, trio.coordinator),
            ctm: Some(Address::repeat_byte(0x7C)),
            ..review(Some(OWNER), &trio)
        };
        let (result, reviewed) = run(&trio, &recorded).await;
        assert_eq!(
            result.errors, 2,
            "the live CHAIN_TYPE_MANAGER and the recorded one both disagree with the review"
        );
        assert_eq!(reviewed, 2);
    }
}
