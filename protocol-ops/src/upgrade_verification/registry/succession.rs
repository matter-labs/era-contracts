//! Executor SUCCESSION: the governance calls that hand a domain from its live executor (the
//! PREDECESSOR) to a newly deployed one (the SUCCESSOR) when a version changes the executor's code
//! (`docs/upgrade-operations.md#executor-succession`). An upgrade that replaces an executor
//! carries them right BEFORE its executor legs, which then target the successor.
//!
//! The calls are fixed shapes with no authored calldata — every one is a function of the
//! predecessor, the successor and the domain's own contracts — so, like the legs, the merge
//! DERIVES them ([`Successions::calls`]) and the verifier re-derives them from the same prepare
//! summaries and holds the bundle to them byte for byte. They are not external actions. The
//! Solidity statement of the same shapes is `deploy-scripts/upgrade/default-upgrade/
//! ExecutorSuccessionLib.sol`, which the Foundry harnesses use:
//!
//! * the core domain, one call: `predecessor.forward([ProxyAdmin.transferOwnership(successor)])`
//!   (the ecosystem `ProxyAdmin` is a one-step `Ownable`);
//! * a CTM domain, three calls: `predecessor.forward([ctm.transferOwnership(successor),
//!   ctmProxyAdmin.transferOwnership(successor), serverNotifier.transferOwnership(successor)])`,
//!   `successor.acceptCTMOwnership()`, `successor.forward([serverNotifier.acceptOwnership()])`.
//!
//! Core first, then the CTM, all with no value.
//!
//! # Where the inputs come from
//!
//! Each prepare that replaces its domain's executor reports, in its `[registry]` summary, the
//! predecessor (`core_predecessor_executor_addr` / `ctm_predecessor_executor_addr`, zero when it
//! replaces nothing) beside the successor (`core_upgrade_executor_addr` /
//! `ctm_upgrade_executor_addr`), and writes the successor's deploy-time record
//! (`[upgrade_executors]`, [`super::records`]). The domain contracts the handover moves are the
//! ones the successor was CONSTRUCTED over, read from that record — so the contracts handed over
//! are, by construction, the ones the successor is bound to. The ServerNotifier is the CTM
//! prepare's `[deployed_addresses] server_notifier_proxy_addr`; the verifier holds it against the
//! CTM's live `serverNotifierAddress()`.
//!
//! # What the verifier holds them to
//!
//! Before execution ([`verify_succession_preconditions`]): each predecessor HOLDS its domain now —
//! it owns the ecosystem `ProxyAdmin` (core), or the CTM, the CTM-domain `ProxyAdmin` and the
//! ServerNotifier with no nomination outstanding on either `Ownable2Step` (CTM) — and is bound to
//! exactly the contracts the successor is. The successor's own construction, bindings, owner and
//! nominations are the lifecycle checks every executor gets ([`super::lifecycle`]). After a replay
//! (`applied`), the successor holds the domain with nothing outstanding.

use alloy::primitives::{Address, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolCall;
use anyhow::Context;

use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::report::VerificationResult;

use super::lifecycle::LifecycleBindings;
use super::provenance::{expect_code_present, tolerate};
use super::upgrade::expect_owned_by;
use super::views::{
    CTMUpgradeExecutorView, CoreUpgradeExecutorView, CtmView, ForwardedCall, Ownable2StepView,
};

/// `[registry]` of the core prepare: the executor the core domain is handed FROM (zero when the
/// run replaces none).
pub(crate) const CORE_PREDECESSOR_FIELD: &str = "core_predecessor_executor_addr";
/// `[registry]` of the core prepare: the executor the core leg targets (the successor when one
/// was deployed).
pub(crate) const CORE_EXECUTOR_FIELD: &str = "core_upgrade_executor_addr";
/// `[registry]` of a CTM prepare: the executor the CTM domain is handed FROM (zero when the run
/// replaces none).
pub(crate) const CTM_PREDECESSOR_FIELD: &str = "ctm_predecessor_executor_addr";
/// `[registry]` of a CTM prepare: the executor the CTM legs target.
pub(crate) const CTM_EXECUTOR_FIELD: &str = "ctm_upgrade_executor_addr";
/// Where a CTM prepare names the CTM's ServerNotifier proxy, the third contract a CTM succession
/// hands over.
pub(crate) const SERVER_NOTIFIER_PATH: [&str; 2] =
    ["deployed_addresses", "server_notifier_proxy_addr"];

/// The domain a succession hands over, with the contracts it moves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SuccessionDomain {
    /// The ecosystem domain: its shared `ProxyAdmin`.
    Core { proxy_admin: Address },
    /// One CTM domain: the CTM, its `ProxyAdmin` and its ServerNotifier.
    Ctm {
        ctm: Address,
        ctm_proxy_admin: Address,
        server_notifier: Address,
    },
}

/// One domain handed from `predecessor` to `successor`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ExecutorSuccession {
    pub(crate) predecessor: Address,
    pub(crate) successor: Address,
    pub(crate) domain: SuccessionDomain,
}

fn call(target: Address, data: Vec<u8>) -> GovernanceCall {
    GovernanceCall {
        target,
        value: U256::ZERO,
        data,
    }
}

fn inner(target: Address, data: Vec<u8>) -> ForwardedCall {
    ForwardedCall {
        target,
        value: U256::ZERO,
        data: data.into(),
    }
}

fn transfer_ownership(to: Address) -> Vec<u8> {
    Ownable2StepView::transferOwnershipCall { newOwner: to }.abi_encode()
}

impl ExecutorSuccession {
    /// The domain, as the report names it.
    pub(crate) fn domain_name(&self) -> &'static str {
        match self.domain {
            SuccessionDomain::Core { .. } => "core",
            SuccessionDomain::Ctm { .. } => "CTM",
        }
    }

    /// The governance calls of this succession, in bundle order (see the module docs) — the
    /// encoding of `ExecutorSuccessionLib.coreCalls` / `ctmCalls`.
    pub(crate) fn calls(&self) -> Vec<GovernanceCall> {
        match self.domain {
            SuccessionDomain::Core { proxy_admin } => vec![call(
                self.predecessor,
                CoreUpgradeExecutorView::forwardCall {
                    _calls: vec![inner(proxy_admin, transfer_ownership(self.successor))],
                }
                .abi_encode(),
            )],
            SuccessionDomain::Ctm {
                ctm,
                ctm_proxy_admin,
                server_notifier,
            } => vec![
                call(
                    self.predecessor,
                    CTMUpgradeExecutorView::forwardCall {
                        _calls: vec![
                            inner(ctm, transfer_ownership(self.successor)),
                            inner(ctm_proxy_admin, transfer_ownership(self.successor)),
                            inner(server_notifier, transfer_ownership(self.successor)),
                        ],
                    }
                    .abi_encode(),
                ),
                call(
                    self.successor,
                    CTMUpgradeExecutorView::acceptCTMOwnershipCall {}.abi_encode(),
                ),
                call(
                    self.successor,
                    CTMUpgradeExecutorView::forwardCall {
                        _calls: vec![inner(
                            server_notifier,
                            Ownable2StepView::acceptOwnershipCall {}.abi_encode(),
                        )],
                    }
                    .abi_encode(),
                ),
            ],
        }
    }

    /// One line per call of [`Self::calls`], for the report.
    pub(crate) fn describe_calls(&self) -> Vec<String> {
        let (p, s) = (self.predecessor, self.successor);
        match self.domain {
            SuccessionDomain::Core { proxy_admin } => vec![format!(
                "{p}.forward([ProxyAdmin {proxy_admin}.transferOwnership({s})])"
            )],
            SuccessionDomain::Ctm {
                ctm,
                ctm_proxy_admin,
                server_notifier,
            } => vec![
                format!(
                    "{p}.forward([CTM {ctm}, ProxyAdmin {ctm_proxy_admin}, ServerNotifier \
                     {server_notifier}].transferOwnership({s}))"
                ),
                format!("{s}.acceptCTMOwnership()"),
                format!("{s}.forward([ServerNotifier {server_notifier}.acceptOwnership()])"),
            ],
        }
    }
}

/// The successions a package carries, in bundle order: the core domain's, then the CTM's.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Successions {
    pub(crate) core: Option<ExecutorSuccession>,
    pub(crate) ctm: Option<ExecutorSuccession>,
}

impl Successions {
    /// Core first, then the CTM.
    pub(crate) fn iter(&self) -> impl Iterator<Item = &ExecutorSuccession> {
        self.core.iter().chain(self.ctm.iter())
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.core.is_none() && self.ctm.is_none()
    }

    /// Every succession call, in bundle order.
    pub(crate) fn calls(&self) -> Vec<GovernanceCall> {
        self.iter().flat_map(ExecutorSuccession::calls).collect()
    }

    /// Every executor the successions name, predecessors and successors, with the role a reviewer
    /// reads it under.
    pub(crate) fn executors(&self) -> Vec<(Address, &'static str)> {
        let mut executors = Vec::new();
        if let Some(core) = &self.core {
            executors.push((core.predecessor, "the predecessor core executor"));
            executors.push((core.successor, "the successor core executor"));
        }
        if let Some(ctm) = &self.ctm {
            executors.push((ctm.predecessor, "the predecessor CTM executor"));
            executors.push((ctm.successor, "the successor CTM executor"));
        }
        executors
    }
}

/// A nonzero address at `path` under `body`: `None` when absent or zero, an error when present
/// but not an address.
fn address_in(body: &toml::value::Table, path: &[&str]) -> anyhow::Result<Option<Address>> {
    let Some((last, parents)) = path.split_last() else {
        return Ok(None);
    };
    let mut table = body;
    for (depth, key) in parents.iter().enumerate() {
        match table.get(*key) {
            Some(toml::Value::Table(next)) => table = next,
            Some(other) => anyhow::bail!(
                "[{}] must be a table (got {})",
                path[..=depth].join("."),
                other.type_str()
            ),
            None => return Ok(None),
        }
    }
    let Some(value) = table.get(*last) else {
        return Ok(None);
    };
    let field = path.join(".");
    let raw = value
        .as_str()
        .with_context(|| format!("{field} must be an address string"))?;
    let address: Address = raw
        .parse()
        .with_context(|| format!("{field} = {raw:?} is not an address"))?;
    Ok((!address.is_zero()).then_some(address))
}

/// The `[upgrade_executors]` record a prepare body carries (none when absent).
fn record_in(body: &toml::value::Table) -> anyhow::Result<UpgradeExecutorsRecord> {
    match body.get("upgrade_executors") {
        Some(value) => value
            .clone()
            .try_into()
            .context("[upgrade_executors] does not decode as an executor record"),
        None => Ok(UpgradeExecutorsRecord::default()),
    }
}

/// `reported` (a field the prepare reports for the domain) against the record's value: a
/// disagreement means the successor was built over a contract other than the one the prepare
/// names. An unreported field is not compared.
fn cross_check_record(
    what: &str,
    field: &str,
    recorded: Address,
    reported: Option<Address>,
) -> anyhow::Result<()> {
    if let Some(reported) = reported {
        anyhow::ensure!(
            reported == recorded,
            "the successor executor's record says it was built over {what} {recorded}, but the \
             prepare reports {field} {reported}: the succession would hand over a contract the \
             successor is not bound to"
        );
    }
    Ok(())
}

/// The predecessor and successor a prepare body reports for a domain, when it replaces the
/// domain's executor: `None` when the predecessor is absent or zero. Refuses a predecessor
/// without a successor, and one that is its own successor.
fn reported_pair(
    body: &toml::value::Table,
    predecessor_field: &str,
    executor_field: &str,
) -> anyhow::Result<Option<(Address, Address)>> {
    let Some(predecessor) = address_in(body, &["registry", predecessor_field])? else {
        return Ok(None);
    };
    let successor = address_in(body, &["registry", executor_field])?.with_context(|| {
        format!(
            "[registry] reports {predecessor_field} {predecessor} but no {executor_field} \
             (missing or zero): a domain handed from its executor to no successor"
        )
    })?;
    anyhow::ensure!(
        predecessor != successor,
        "[registry] reports {predecessor_field} {predecessor} equal to {executor_field}: an \
         executor cannot succeed itself"
    );
    Ok(Some((predecessor, successor)))
}

/// The core succession a core prepare's body describes, if it replaces the core executor. The
/// ecosystem `ProxyAdmin` handed over is the one the successor's record says it was built over,
/// cross-checked against `[upgrade_addresses.shared] transparent_proxy_admin` when reported.
pub(crate) fn core_succession_in(
    body: &toml::value::Table,
) -> anyhow::Result<Option<ExecutorSuccession>> {
    let Some((predecessor, successor)) =
        reported_pair(body, CORE_PREDECESSOR_FIELD, CORE_EXECUTOR_FIELD)?
    else {
        return Ok(None);
    };
    let record = record_in(body)?.core_executor.with_context(|| {
        format!(
            "[registry] hands the core domain from {predecessor} to {successor}, but there is no \
             [upgrade_executors.core_executor] record of the successor: the ProxyAdmin it is \
             bound to, and so the handover, cannot be derived"
        )
    })?;
    anyhow::ensure!(
        record.address == successor,
        "[upgrade_executors.core_executor] records {}, but the successor \
         ({CORE_EXECUTOR_FIELD}) is {successor}: the record describes another executor",
        record.address
    );
    anyhow::ensure!(
        !record.proxy_admin.is_zero(),
        "[upgrade_executors.core_executor] records a zero proxy_admin"
    );
    cross_check_record(
        "ProxyAdmin",
        "upgrade_addresses.shared.transparent_proxy_admin",
        record.proxy_admin,
        address_in(
            body,
            &["upgrade_addresses", "shared", "transparent_proxy_admin"],
        )?,
    )?;
    Ok(Some(ExecutorSuccession {
        predecessor,
        successor,
        domain: SuccessionDomain::Core {
            proxy_admin: record.proxy_admin,
        },
    }))
}

/// The CTM succession a CTM prepare's body describes, if it replaces the CTM executor. The CTM
/// and its `ProxyAdmin` are the ones the successor's record says it was built over, cross-checked
/// against `[state_transition] chain_type_manager_proxy` and `[deployed_addresses]
/// transparent_proxy_admin` when reported; the ServerNotifier is
/// `[deployed_addresses] server_notifier_proxy_addr`, required.
pub(crate) fn ctm_succession_in(
    body: &toml::value::Table,
) -> anyhow::Result<Option<ExecutorSuccession>> {
    let Some((predecessor, successor)) =
        reported_pair(body, CTM_PREDECESSOR_FIELD, CTM_EXECUTOR_FIELD)?
    else {
        return Ok(None);
    };
    let record = record_in(body)?.ctm_executor.with_context(|| {
        format!(
            "[registry] hands the CTM domain from {predecessor} to {successor}, but there is no \
             [upgrade_executors.ctm_executor] record of the successor: the CTM and ProxyAdmin it \
             is bound to, and so the handover, cannot be derived"
        )
    })?;
    anyhow::ensure!(
        record.address == successor,
        "[upgrade_executors.ctm_executor] records {}, but the successor ({CTM_EXECUTOR_FIELD}) \
         is {successor}: the record describes another executor",
        record.address
    );
    anyhow::ensure!(
        !record.chain_type_manager.is_zero() && !record.ctm_proxy_admin.is_zero(),
        "[upgrade_executors.ctm_executor] records a zero chain_type_manager or ctm_proxy_admin"
    );
    cross_check_record(
        "CTM",
        "state_transition.chain_type_manager_proxy",
        record.chain_type_manager,
        address_in(body, &["state_transition", "chain_type_manager_proxy"])?,
    )?;
    cross_check_record(
        "ProxyAdmin",
        "deployed_addresses.transparent_proxy_admin",
        record.ctm_proxy_admin,
        address_in(body, &["deployed_addresses", "transparent_proxy_admin"])?,
    )?;
    let server_notifier = address_in(body, &SERVER_NOTIFIER_PATH)?.with_context(|| {
        format!(
            "[registry] hands the CTM domain from {predecessor} to {successor}, but the prepare \
             names no ServerNotifier ({}, missing or zero): the notifier's handover cannot be \
             derived",
            SERVER_NOTIFIER_PATH.join(".")
        )
    })?;
    Ok(Some(ExecutorSuccession {
        predecessor,
        successor,
        domain: SuccessionDomain::Ctm {
            ctm: record.chain_type_manager,
            ctm_proxy_admin: record.ctm_proxy_admin,
            server_notifier,
        },
    }))
}

impl Successions {
    /// The successions of a core prepare body and (at most one) CTM prepare body — the per-prepare
    /// outputs at merge time, or the merged package's `[core]` and `[ctms.<key>]`.
    pub(crate) fn in_bodies(
        core: Option<&toml::value::Table>,
        ctm: Option<&toml::value::Table>,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            core: core
                .map(core_succession_in)
                .transpose()
                .context("the core prepare's executor succession")?
                .flatten(),
            ctm: ctm
                .map(ctm_succession_in)
                .transpose()
                .context("the CTM prepare's executor succession")?
                .flatten(),
        })
    }
}

// ───────────────────────── before execution ─────────────────────────

/// One binding a predecessor answers against the contract the succession hands over and the
/// successor's live binding: all three must be one contract, or the successor would take over a
/// domain other than the predecessor's.
fn expect_same_binding(
    result: &mut VerificationResult,
    name: &str,
    handed_over: Address,
    predecessor: Option<Address>,
    successor: Option<Address>,
) {
    let mut agreed = true;
    for (whose, live) in [
        ("the predecessor executor", predecessor),
        ("the successor executor", successor),
    ] {
        match live {
            Some(live) if live == handed_over => {}
            Some(live) => {
                agreed = false;
                result.report_error(&format!(
                    "{whose} is bound to {name} {live}, but the succession hands over \
                     {handed_over}: the successor would be bound to another domain than the one \
                     it takes over"
                ));
            }
            // Unreadable, already reported when read.
            None => agreed = false,
        }
    }
    if agreed {
        result.report_ok(&format!(
            "the predecessor and the successor are both bound to {name} {handed_over}, the one \
             the succession hands over"
        ));
    }
}

/// Holds each succession to the live chain before the bundle runs: the predecessor must hold the
/// domain the succession moves, with no nomination outstanding on it, and be bound to exactly the
/// contracts the successor is (`bindings`, the successor's live answers read by the lifecycle
/// check). The successor's construction, owner and nominations are checked as every executor's
/// are; the predecessor's owner by the caller beside them.
///
/// Reads, per succession (core first): the predecessor's code; for the core, its `PROXY_ADMIN()`
/// and the ProxyAdmin's owner; for a CTM, its `CHAIN_TYPE_MANAGER()` and `CTM_PROXY_ADMIN()`, the
/// CTM's owner, the ProxyAdmin's owner, the CTM's pending owner and `serverNotifierAddress()`,
/// then the ServerNotifier's owner and pending owner.
pub(super) async fn verify_succession_preconditions<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    successions: &Successions,
    bindings: &LifecycleBindings,
) -> anyhow::Result<()> {
    for succession in successions.iter() {
        let predecessor = succession.predecessor;
        match succession.domain {
            SuccessionDomain::Core { proxy_admin } => {
                let label = "the predecessor core executor";
                result.print_info(&format!(
                    "  the core domain is handed from {predecessor} to {}",
                    succession.successor
                ));
                if !expect_code_present(provider, result, label, predecessor).await? {
                    continue;
                }
                let bound = tolerate(
                    CoreUpgradeExecutorView::new(predecessor, provider)
                        .PROXY_ADMIN()
                        .call()
                        .await,
                    result,
                    "the predecessor core executor's PROXY_ADMIN",
                );
                expect_same_binding(
                    result,
                    "PROXY_ADMIN",
                    proxy_admin,
                    bound,
                    bindings.core_proxy_admin,
                );
                expect_owned_by(
                    provider,
                    result,
                    "the ecosystem ProxyAdmin",
                    proxy_admin,
                    predecessor,
                    label,
                )
                .await;
            }
            SuccessionDomain::Ctm {
                ctm,
                ctm_proxy_admin,
                server_notifier,
            } => {
                let label = "the predecessor CTM executor";
                result.print_info(&format!(
                    "  the CTM domain is handed from {predecessor} to {}",
                    succession.successor
                ));
                if !expect_code_present(provider, result, label, predecessor).await? {
                    continue;
                }
                let executor = CTMUpgradeExecutorView::new(predecessor, provider);
                let bound_ctm = tolerate(
                    executor.CHAIN_TYPE_MANAGER().call().await,
                    result,
                    "the predecessor CTM executor's CHAIN_TYPE_MANAGER",
                );
                let bound_admin = tolerate(
                    executor.CTM_PROXY_ADMIN().call().await,
                    result,
                    "the predecessor CTM executor's CTM_PROXY_ADMIN",
                );
                expect_same_binding(result, "CHAIN_TYPE_MANAGER", ctm, bound_ctm, bindings.ctm);
                expect_same_binding(
                    result,
                    "CTM_PROXY_ADMIN",
                    ctm_proxy_admin,
                    bound_admin,
                    bindings.ctm_proxy_admin,
                );
                expect_owned_by(provider, result, "the CTM", ctm, predecessor, label).await;
                expect_owned_by(
                    provider,
                    result,
                    "the CTM-domain ProxyAdmin",
                    ctm_proxy_admin,
                    predecessor,
                    label,
                )
                .await;
                let ctm_view = CtmView::new(ctm, provider);
                let pending = tolerate(
                    ctm_view.pendingOwner().call().await,
                    result,
                    "the CTM's pending owner",
                );
                expect_no_nomination(result, "the CTM", pending);
                match tolerate(
                    ctm_view.serverNotifierAddress().call().await,
                    result,
                    "the CTM's serverNotifierAddress()",
                ) {
                    Some(live) if live == server_notifier => result.report_ok(&format!(
                        "the ServerNotifier the succession hands over is the CTM's \
                         ({server_notifier})"
                    )),
                    Some(live) => result.report_error(&format!(
                        "the succession hands over ServerNotifier {server_notifier}, but the \
                         CTM's serverNotifierAddress() is {live}: the CTM's own notifier would \
                         stay with the predecessor"
                    )),
                    None => {}
                }
                expect_owned_by(
                    provider,
                    result,
                    "the ServerNotifier",
                    server_notifier,
                    predecessor,
                    label,
                )
                .await;
                let pending = tolerate(
                    Ownable2StepView::new(server_notifier, provider)
                        .pendingOwner()
                        .call()
                        .await,
                    result,
                    "the ServerNotifier's pending owner",
                );
                expect_no_nomination(result, "the ServerNotifier", pending);
            }
        }
    }
    Ok(())
}

/// A domain contract's `pendingOwner()` before the succession: a nominee could accept before the
/// bundle runs and take the contract the succession moves. An unreadable one (`None`) was reported
/// when read.
fn expect_no_nomination(result: &mut VerificationResult, label: &str, pending: Option<Address>) {
    match pending {
        Some(pending) if pending.is_zero() => {
            result.report_ok(&format!("{label} has no pending owner"))
        }
        Some(pending) => result.report_error(&format!(
            "{label} has a pending owner {pending}: a nomination is outstanding that could take it \
             before the succession hands it over"
        )),
        None => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{keccak256, Bytes, B256};
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    const PREDECESSOR: Address = Address::repeat_byte(0xD0);
    const SUCCESSOR: Address = Address::repeat_byte(0xD1);
    const ECO_ADMIN: Address = Address::repeat_byte(0xA0);
    const CTM: Address = Address::repeat_byte(0xC7);
    const CTM_ADMIN: Address = Address::repeat_byte(0xA7);
    const NOTIFIER: Address = Address::repeat_byte(0x5E);
    const STRANGER: Address = Address::repeat_byte(0x99);

    fn selector(signature: &str) -> [u8; 4] {
        keccak256(signature.as_bytes())[..4].try_into().unwrap()
    }

    /// The selectors the calls are encoded with are the Solidity ones `ExecutorSuccessionLib`
    /// uses, transcribed from the signatures rather than from the `sol!` block.
    #[test]
    fn the_succession_selectors_are_the_solidity_ones() {
        let forward = selector("forward((address,uint256,bytes)[])");
        assert_eq!(CoreUpgradeExecutorView::forwardCall::SELECTOR, forward);
        assert_eq!(CTMUpgradeExecutorView::forwardCall::SELECTOR, forward);
        assert_eq!(
            CTMUpgradeExecutorView::acceptCTMOwnershipCall::SELECTOR,
            selector("acceptCTMOwnership()")
        );
        assert_eq!(
            Ownable2StepView::transferOwnershipCall::SELECTOR,
            selector("transferOwnership(address)")
        );
        assert_eq!(
            Ownable2StepView::acceptOwnershipCall::SELECTOR,
            selector("acceptOwnership()")
        );
    }

    fn core() -> ExecutorSuccession {
        ExecutorSuccession {
            predecessor: PREDECESSOR,
            successor: SUCCESSOR,
            domain: SuccessionDomain::Core {
                proxy_admin: ECO_ADMIN,
            },
        }
    }

    fn ctm() -> ExecutorSuccession {
        ExecutorSuccession {
            predecessor: PREDECESSOR,
            successor: SUCCESSOR,
            domain: SuccessionDomain::Ctm {
                ctm: CTM,
                ctm_proxy_admin: CTM_ADMIN,
                server_notifier: NOTIFIER,
            },
        }
    }

    /// `abi.encodeCall(IUpgradeExecutorBase.forward, (calls))`, transcribed: selector, offset,
    /// length, per-element offsets, then each `(target, value, data)` tuple.
    fn transcribed_forward(inner: &[(Address, Vec<u8>)]) -> Vec<u8> {
        let tuples: Vec<(Address, U256, Bytes)> = inner
            .iter()
            .map(|(target, data)| (*target, U256::ZERO, Bytes::from(data.clone())))
            .collect();
        let mut data = selector("forward((address,uint256,bytes)[])").to_vec();
        data.extend((tuples,).abi_encode_params());
        data
    }

    fn transcribed_transfer(to: Address) -> Vec<u8> {
        let mut data = selector("transferOwnership(address)").to_vec();
        data.extend(to.abi_encode());
        data
    }

    /// The core handover is ONE `forward` on the predecessor moving the ProxyAdmin, as
    /// `ExecutorSuccessionLib.coreCalls` encodes it.
    #[test]
    fn the_core_succession_is_one_forward_on_the_predecessor() {
        let calls = core().calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].target, PREDECESSOR);
        assert!(calls[0].value.is_zero());
        assert_eq!(
            calls[0].data,
            transcribed_forward(&[(ECO_ADMIN, transcribed_transfer(SUCCESSOR))])
        );
    }

    /// The CTM handover is the predecessor's three nominations, the successor's
    /// `acceptCTMOwnership`, then its acceptance of the notifier — `ExecutorSuccessionLib.ctmCalls`.
    #[test]
    fn the_ctm_succession_is_three_calls_in_order() {
        let calls = ctm().calls();
        assert_eq!(
            calls.iter().map(|c| c.target).collect::<Vec<_>>(),
            vec![PREDECESSOR, SUCCESSOR, SUCCESSOR]
        );
        assert!(calls.iter().all(|c| c.value.is_zero()));
        assert_eq!(
            calls[0].data,
            transcribed_forward(&[
                (CTM, transcribed_transfer(SUCCESSOR)),
                (CTM_ADMIN, transcribed_transfer(SUCCESSOR)),
                (NOTIFIER, transcribed_transfer(SUCCESSOR)),
            ])
        );
        assert_eq!(calls[1].data, selector("acceptCTMOwnership()").to_vec());
        assert_eq!(
            calls[2].data,
            transcribed_forward(&[(NOTIFIER, selector("acceptOwnership()").to_vec())])
        );
        let both = Successions {
            core: Some(core()),
            ctm: Some(ctm()),
        };
        assert_eq!(both.calls()[0], core().calls()[0], "core first");
        assert_eq!(both.calls().len(), 4);
    }

    fn address(a: Address) -> toml::Value {
        toml::Value::String(format!("{a:#x}"))
    }

    fn table(entries: &[(&str, toml::Value)]) -> toml::value::Table {
        entries
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect()
    }

    fn core_body(predecessor: Address, record_address: Address) -> toml::value::Table {
        table(&[
            (
                "registry",
                toml::Value::Table(table(&[
                    (CORE_PREDECESSOR_FIELD, address(predecessor)),
                    (CORE_EXECUTOR_FIELD, address(SUCCESSOR)),
                ])),
            ),
            (
                "upgrade_executors",
                toml::Value::Table(table(&[(
                    "core_executor",
                    toml::Value::Table(table(&[
                        ("address", address(record_address)),
                        (
                            "create2_salt",
                            toml::Value::String(format!("{:#x}", B256::repeat_byte(0x5A))),
                        ),
                        ("initial_owner", address(Address::repeat_byte(0x60))),
                        ("proxy_admin", address(ECO_ADMIN)),
                    ])),
                )])),
            ),
        ])
    }

    #[test]
    fn a_core_prepare_body_describes_its_succession() {
        assert_eq!(
            core_succession_in(&core_body(PREDECESSOR, SUCCESSOR)).unwrap(),
            Some(core())
        );
        // No predecessor: no succession, whatever else the body says.
        assert_eq!(
            core_succession_in(&core_body(Address::ZERO, SUCCESSOR)).unwrap(),
            None
        );
    }

    #[test]
    fn an_inconsistent_core_succession_is_refused() {
        let err = core_succession_in(&core_body(PREDECESSOR, STRANGER)).unwrap_err();
        assert!(
            format!("{err:#}").contains("describes another executor"),
            "{err:#}"
        );
        let err = core_succession_in(&core_body(SUCCESSOR, SUCCESSOR)).unwrap_err();
        assert!(
            format!("{err:#}").contains("cannot succeed itself"),
            "{err:#}"
        );
        let mut no_record = core_body(PREDECESSOR, SUCCESSOR);
        no_record.remove("upgrade_executors");
        let err = core_succession_in(&no_record).unwrap_err();
        assert!(
            format!("{err:#}").contains("no [upgrade_executors.core_executor]"),
            "{err:#}"
        );
    }

    // ───────────── the predecessor against the live chain ─────────────

    fn word(a: Address) -> Bytes {
        Bytes::from(a.abi_encode())
    }

    /// The live answers of a CTM predecessor that holds its domain, in read order.
    fn ctm_answers() -> Vec<(&'static str, Bytes)> {
        vec![
            ("predecessor.code", Bytes::from_static(&[0x60])),
            ("predecessor.CHAIN_TYPE_MANAGER", word(CTM)),
            ("predecessor.CTM_PROXY_ADMIN", word(CTM_ADMIN)),
            ("ctm.owner", word(PREDECESSOR)),
            ("ctmAdmin.owner", word(PREDECESSOR)),
            ("ctm.pendingOwner", word(Address::ZERO)),
            ("ctm.serverNotifierAddress", word(NOTIFIER)),
            ("notifier.owner", word(PREDECESSOR)),
            ("notifier.pendingOwner", word(Address::ZERO)),
        ]
    }

    fn successor_bindings() -> LifecycleBindings {
        LifecycleBindings {
            core_proxy_admin: Some(ECO_ADMIN),
            ctm: Some(CTM),
            ctm_proxy_admin: Some(CTM_ADMIN),
        }
    }

    async fn run(
        successions: &Successions,
        answers: Vec<(&'static str, Bytes)>,
        bindings: &LifecycleBindings,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for (_, answer) in &answers {
            asserter.push_success(answer);
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_succession_preconditions(&provider, &mut result, successions, bindings)
            .await
            .unwrap();
        assert!(asserter.read_q().is_empty(), "every read was made");
        result
    }

    fn with(
        mut answers: Vec<(&'static str, Bytes)>,
        label: &str,
        value: Address,
    ) -> Vec<(&'static str, Bytes)> {
        answers
            .iter_mut()
            .find(|(name, _)| *name == label)
            .unwrap_or_else(|| panic!("no read named {label}"))
            .1 = word(value);
        answers
    }

    #[tokio::test]
    async fn a_predecessor_holding_its_domain_passes() {
        let ctm_only = Successions {
            core: None,
            ctm: Some(ctm()),
        };
        let result = run(&ctm_only, ctm_answers(), &successor_bindings()).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);

        let core_only = Successions {
            core: Some(core()),
            ctm: None,
        };
        let answers = vec![
            ("predecessor.code", Bytes::from_static(&[0x60])),
            ("predecessor.PROXY_ADMIN", word(ECO_ADMIN)),
            ("ecoAdmin.owner", word(PREDECESSOR)),
        ];
        let result = run(&core_only, answers, &successor_bindings()).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
    }

    /// The predecessor must be the live owner of every contract the succession moves: if anything
    /// else holds one, the handover reverts (or moves nothing) and the legs run on authority the
    /// successor never received.
    #[tokio::test]
    async fn a_predecessor_that_is_not_the_live_owner_fails() {
        let ctm_only = Successions {
            core: None,
            ctm: Some(ctm()),
        };
        for (read, value, needle) in [
            ("ctm.owner", STRANGER, "the CTM is owned by"),
            (
                "ctmAdmin.owner",
                STRANGER,
                "the CTM-domain ProxyAdmin is owned by",
            ),
            ("notifier.owner", STRANGER, "the ServerNotifier is owned by"),
            ("ctm.pendingOwner", STRANGER, "the CTM has a pending owner"),
            (
                "notifier.pendingOwner",
                STRANGER,
                "the ServerNotifier has a pending owner",
            ),
            (
                "ctm.serverNotifierAddress",
                STRANGER,
                "the CTM's serverNotifierAddress() is",
            ),
        ] {
            let result = run(
                &ctm_only,
                with(ctm_answers(), read, value),
                &successor_bindings(),
            )
            .await;
            assert_eq!(result.errors, 1, "{read}: {:?}", result.error_messages);
            assert!(
                result.has_error(needle),
                "{read}: {:?}",
                result.error_messages
            );
        }

        let core_only = Successions {
            core: Some(core()),
            ctm: None,
        };
        let answers = vec![
            ("predecessor.code", Bytes::from_static(&[0x60])),
            ("predecessor.PROXY_ADMIN", word(ECO_ADMIN)),
            ("ecoAdmin.owner", word(SUCCESSOR)),
        ];
        let result = run(&core_only, answers, &successor_bindings()).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("the ecosystem ProxyAdmin is owned by"));
    }

    /// A successor bound to another domain than its predecessor (or a predecessor bound elsewhere
    /// than the contracts handed over) is refused: the successor would take over contracts it
    /// cannot drive, or drive contracts it never took over.
    #[tokio::test]
    async fn a_successor_bound_to_another_domain_fails() {
        let ctm_only = Successions {
            core: None,
            ctm: Some(ctm()),
        };
        let mut elsewhere = successor_bindings();
        elsewhere.ctm = Some(STRANGER);
        let result = run(&ctm_only, ctm_answers(), &elsewhere).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("the successor executor is bound to CHAIN_TYPE_MANAGER"));

        let result = run(
            &ctm_only,
            with(ctm_answers(), "predecessor.CTM_PROXY_ADMIN", STRANGER),
            &successor_bindings(),
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("the predecessor executor is bound to CTM_PROXY_ADMIN"));

        let core_only = Successions {
            core: Some(core()),
            ctm: None,
        };
        let mut elsewhere = successor_bindings();
        elsewhere.core_proxy_admin = Some(STRANGER);
        let answers = vec![
            ("predecessor.code", Bytes::from_static(&[0x60])),
            ("predecessor.PROXY_ADMIN", word(ECO_ADMIN)),
            ("ecoAdmin.owner", word(PREDECESSOR)),
        ];
        let result = run(&core_only, answers, &elsewhere).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("the successor executor is bound to PROXY_ADMIN"));
    }
}
