//! The reviewable inputs of a registry-driven package — the merged prepare TOML
//! (`ecosystem upgrade-prepare-all`'s output) plus the live L1 it targets.
//!
//! The format carries NO protocol version: which version an upgrade moves chains to lives in the
//! `CTMTransition` its transition leg applies, and is read from that object on chain. That is why
//! one loader serves every release.
//!
//! Three kinds, told apart by the CALLDATA governance will execute rather than by a flag. Each is
//! ONE governance bundle, `[governance_calls] calls`:
//!
//! * an UPGRADE, the ordinary case: one contiguous run of 1..3 executor legs in canonical order —
//!   `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)`,
//!   `CTMUpgradeExecutor.applyInfrastructureUpgrade(infrastructureTransition)`,
//!   `CTMUpgradeExecutor.applyCTMUpgrade(transition)` — each present only when its object is.
//!   Everything executable is a function of those objects, so the package's reviewable content is
//!   their addresses and the executors they are sent to.
//! * a BOOTSTRAP edge, the one-time migration onto the registry model: the bundle calls
//!   `migrate()`. Governance executes the list a `RegistryBootstrapSequence` derives (the core
//!   transition rides it), ending in the edge's completion check.
//! * a transition REPLACEMENT: one `CTMUpgradeExecutor.forward` carrying
//!   `ChainTypeManager.replaceUpgradeTransition` (see
//!   `protocol-docs/ecosystem-upgrade-coordination.md#replacing-a-committed-transition`), and no
//!   executor leg.
//!
//! A bundle mixing kinds — legs beside a `migrate()` (beyond the sequence's own core leg) or beside
//! a replacing `forward` — is refused, as is one that is none of them. In every kind an object is
//! recovered from the calldata, never from the prepare's summary of it, and the summary field is
//! then a cross-check: a disagreement means the reviewer read one upgrade and governance would sign
//! another.

use std::path::Path;

use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::sol_types::SolCall;
use anyhow::Context;

use crate::common::external_actions::ExternalAction;
use crate::common::forge::scripts::member_deployments::MemberDeployments;
use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::common::governance_calls::{decode_calls, GovernanceCall, GovernanceCallsTable};

use super::records::{member_records_in, records_in};
use super::views::{CTMUpgradeExecutorView, CoreUpgradeExecutorView};

/// `RegistryBootstrapMigration.migrate()`.
pub(crate) const MIGRATE_SELECTOR: [u8; 4] = [0x8f, 0xd3, 0xab, 0x80];
/// `Ownable2Step.transferOwnership(address)` — the nomination a bundle would smuggle past a
/// reviewer, which the tests append to a derived sequence.
#[cfg(test)]
pub(crate) const TRANSFER_OWNERSHIP_SELECTOR: [u8; 4] = [0xf2, 0xfd, 0xe3, 0x8b];

/// A merged prepare output, classified by the kind of upgrade it drives.
#[derive(Debug)]
pub(crate) enum RegistryPackage {
    /// The ordinary case: 1..3 executor legs, sent to the domain executors directly.
    Upgrade(UpgradePackage),
    /// The one-time migration onto the registry model.
    Bootstrap(BootstrapPackage),
    /// A compare-and-replace of a committed transition.
    Replacement(Box<ReplacementPackage>),
}

impl RegistryPackage {
    /// Reads `ecosystem_toml` and decides which kind of upgrade it drives, from its calldata: a
    /// `migrate()` call makes a bootstrap edge, a `forward` carrying `replaceUpgradeTransition` a
    /// replacement, and executor legs an upgrade. A package mixing them, or that is none of them,
    /// is REFUSED rather than verified as the nearest match: it is an input this tool cannot
    /// review.
    pub(crate) fn load(ecosystem_toml: &Path) -> anyhow::Result<Self> {
        Self::load_if_registry(ecosystem_toml)?.with_context(|| {
            format!(
                "{} is neither kind of package this tool reviews: its governance bundle calls no \
                 executor entrypoint (applyL1Upgrade, applyInfrastructureUpgrade, \
                 applyCTMUpgrade), no `migrate()` and no `forward` that replaces a transition, so \
                 this tool cannot say what it does",
                ecosystem_toml.display()
            )
        })
    }

    /// [`Self::load`], except that a bundle carrying none of the three kinds' calls is `None`
    /// rather than refused: a governance TOML that is not a registry package at all.
    pub(crate) fn load_if_registry(ecosystem_toml: &Path) -> anyhow::Result<Option<Self>> {
        let root = read_toml(ecosystem_toml)?;
        let calls = bundle_in(&root)?;
        let legs = recover_legs(&calls)?;
        let migrates = migrate_targets(&calls);
        let replacement = recover_replacement(&calls)?;

        if !migrates.is_empty() {
            if let Some(forward) = &replacement {
                anyhow::bail!(
                    "mixed kinds: the bundle runs a bootstrap edge (`migrate()`) and replaces a \
                     transition (`forward` at call {}) in one package; each is reviewed on its own",
                    forward.index
                );
            }
            // The bootstrap sequence applies the core transition itself; a CTM leg has no place
            // in it — the edge installs its release through the migration.
            if let Some(leg) = legs.iter().find(|leg| leg.kind.is_ctm()) {
                anyhow::bail!(
                    "mixed kinds: the bundle runs a bootstrap edge (`migrate()`) and also calls \
                     {} (call {}): a bootstrap carries no CTM executor leg",
                    leg.kind.entrypoint(),
                    leg.index
                );
            }
            return Ok(Some(Self::Bootstrap(BootstrapPackage::load(
                ecosystem_toml,
                &root,
                calls,
            )?)));
        }
        if let Some(forward) = replacement {
            if let Some(leg) = legs.first() {
                anyhow::bail!(
                    "mixed kinds: the bundle replaces a transition (`forward` at call {}) and also \
                     calls {} (call {}): a replacement package carries no executor leg",
                    forward.index,
                    leg.kind.entrypoint(),
                    leg.index
                );
            }
            return Ok(Some(Self::Replacement(Box::new(ReplacementPackage::load(
                ecosystem_toml,
                &root,
                forward,
                calls,
            )?))));
        }
        if legs.is_empty() {
            return Ok(None);
        }
        Ok(Some(Self::Upgrade(UpgradePackage::load(
            ecosystem_toml,
            &root,
            calls,
            legs,
        )?)))
    }
}

/// One of the three executor entrypoints an upgrade's governance bundle calls, in canonical order
/// (the derive order IS the canonical order: core, then CTM infrastructure, then the transition).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum LegKind {
    /// `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)`: a Core-domain
    /// `ProxyUpgradeTransition`.
    Core,
    /// `CTMUpgradeExecutor.applyInfrastructureUpgrade(infrastructureTransition)`: a CTM-domain
    /// `ProxyUpgradeTransition`.
    Infrastructure,
    /// `CTMUpgradeExecutor.applyCTMUpgrade(transition)`: a `CTMTransition`.
    Transition,
}

impl LegKind {
    /// The order the legs must run in: ecosystem singletons first, then the CTM domain's
    /// infrastructure, then the transition commit that may need the new CTM implementation.
    pub(crate) const CANONICAL_ORDER: [LegKind; 3] =
        [Self::Core, Self::Infrastructure, Self::Transition];

    fn selector(self) -> [u8; 4] {
        match self {
            Self::Core => CoreUpgradeExecutorView::applyL1UpgradeCall::SELECTOR,
            Self::Infrastructure => {
                CTMUpgradeExecutorView::applyInfrastructureUpgradeCall::SELECTOR
            }
            Self::Transition => CTMUpgradeExecutorView::applyCTMUpgradeCall::SELECTOR,
        }
    }

    /// The leg whose entrypoint `data` calls, by selector.
    fn of(data: &[u8]) -> Option<Self> {
        let selector = data.get(..4)?;
        Self::CANONICAL_ORDER
            .into_iter()
            .find(|kind| kind.selector()[..] == *selector)
    }

    /// `Executor.entrypoint`, as the report names it.
    pub(crate) fn entrypoint(self) -> &'static str {
        match self {
            Self::Core => "CoreUpgradeExecutor.applyL1Upgrade",
            Self::Infrastructure => "CTMUpgradeExecutor.applyInfrastructureUpgrade",
            Self::Transition => "CTMUpgradeExecutor.applyCTMUpgrade",
        }
    }

    /// The prepare summary field naming this leg's object (`[core.registry]` for the core leg,
    /// `[ctms.*.registry]` for the CTM legs).
    pub(crate) fn summary_field(self) -> &'static str {
        match self {
            Self::Core => "core_transition_addr",
            Self::Infrastructure => "ctm_infrastructure_transition_addr",
            Self::Transition => "ctm_transition_addr",
        }
    }

    /// The prepare summary field naming the executor this leg is sent to.
    pub(crate) fn executor_field(self) -> &'static str {
        if self.is_ctm() {
            "ctm_upgrade_executor_addr"
        } else {
            "core_upgrade_executor_addr"
        }
    }

    /// Whether the leg is sent to the CTM domain's executor.
    pub(crate) fn is_ctm(self) -> bool {
        self != Self::Core
    }

    /// The call governance signs for this leg over `object`, encoded from the executors' ABI.
    pub(crate) fn encode(self, object: Address) -> Vec<u8> {
        match self {
            Self::Core => CoreUpgradeExecutorView::applyL1UpgradeCall {
                _coreTransition: object,
            }
            .abi_encode(),
            Self::Infrastructure => CTMUpgradeExecutorView::applyInfrastructureUpgradeCall {
                _infrastructureTransition: object,
            }
            .abi_encode(),
            Self::Transition => CTMUpgradeExecutorView::applyCTMUpgradeCall {
                _transition: object,
            }
            .abi_encode(),
        }
    }

    /// The object `data` applies, when `data` is EXACTLY this entrypoint's calldata — a canonical
    /// encoding with nothing appended, since anything else is not a call the merge derives.
    fn decode(self, data: &[u8]) -> Option<Address> {
        let object = match self {
            Self::Core => {
                CoreUpgradeExecutorView::applyL1UpgradeCall::abi_decode_validate(data)
                    .ok()?
                    ._coreTransition
            }
            Self::Infrastructure => {
                CTMUpgradeExecutorView::applyInfrastructureUpgradeCall::abi_decode_validate(data)
                    .ok()?
                    ._infrastructureTransition
            }
            Self::Transition => {
                CTMUpgradeExecutorView::applyCTMUpgradeCall::abi_decode_validate(data)
                    .ok()?
                    ._transition
            }
        };
        (self.encode(object) == data).then_some(object)
    }
}

/// One executor leg as the calldata states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RecoveredLeg {
    pub(crate) kind: LegKind,
    /// The call's index in the bundle.
    pub(crate) index: usize,
    /// The call's target: the domain executor it is sent to.
    pub(crate) executor: Address,
    /// The object it applies.
    pub(crate) object: Address,
}

/// Every executor leg in the bundle, in bundle order.
///
/// A call counts as a leg when it carries one of the three entrypoints' selectors; it must then BE
/// that entrypoint's calldata exactly, carry no value (the entrypoints are not payable) and name a
/// nonzero object — anything else is refused rather than verified as the nearest leg. A leg kind
/// appearing twice is refused too: the second application of an object is not a bundle the merge
/// produces.
pub(crate) fn recover_legs(calls: &[GovernanceCall]) -> anyhow::Result<Vec<RecoveredLeg>> {
    let mut legs: Vec<RecoveredLeg> = Vec::new();
    for (index, call) in calls.iter().enumerate() {
        let Some(kind) = LegKind::of(&call.data) else {
            continue;
        };
        let entrypoint = kind.entrypoint();
        let object = kind.decode(&call.data).with_context(|| {
            format!(
                "call {index} carries {entrypoint}'s selector but is not exactly its calldata \
                 (one address argument, canonically encoded, nothing appended)"
            )
        })?;
        anyhow::ensure!(
            call.value.is_zero(),
            "call {index} ({entrypoint}) carries value {}: the executor entrypoints are not \
             payable, and an upgrade leg moves none",
            call.value
        );
        anyhow::ensure!(
            !object.is_zero(),
            "call {index} ({entrypoint}) applies the zero address"
        );
        if let Some(previous) = legs.iter().find(|leg| leg.kind == kind) {
            anyhow::bail!(
                "duplicate leg: the bundle calls {entrypoint} twice (calls {} and {index}); an \
                 upgrade carries each leg at most once",
                previous.index
            );
        }
        legs.push(RecoveredLeg {
            kind,
            index,
            executor: call.target,
            object,
        });
    }
    Ok(legs)
}

/// An upgrade: 1..3 executor legs recovered from the calldata, each reconciled with the prepare
/// summary that names its object and executor.
///
/// The package carries no derived payload of its own to check: everything executable is a
/// function of the leg objects, read on chain. Its CTM inputs are required only when a CTM leg
/// exists — a core-only upgrade needs no CTM prepare to manufacture one.
#[derive(Debug)]
pub(crate) struct UpgradePackage {
    /// The legs, in bundle order (their order and contiguity are judged by the verifier).
    pub(crate) legs: Vec<RecoveredLeg>,
    /// The CTM key under `[ctms]` (e.g. `zksync_os`): required when a CTM leg exists, otherwise
    /// present when the package carries a CTM section at all.
    pub(crate) ctm_key: Option<String>,
    /// `[core.registry] core_transition_addr`, reconciled with the core leg at load.
    pub(crate) reported_core_transition: Option<Address>,
    /// `[ctms.*.registry] ctm_infrastructure_transition_addr`, reconciled with the
    /// infrastructure leg at load.
    pub(crate) reported_infrastructure_transition: Option<Address>,
    /// `[ctms.*.registry] ctm_transition_addr`, reconciled with the transition leg at load.
    pub(crate) reported_ctm_transition: Option<Address>,
    /// `[ctms.*.registry] ctm_upgrade_executor_addr`, reconciled with the CTM legs' target.
    pub(crate) reported_ctm_executor: Option<Address>,
    /// `[ctms.*.state_transition] chain_type_manager_proxy` — the CTM this package upgrades, the
    /// independently reviewed value the CTM executor's `CHAIN_TYPE_MANAGER` is held against
    /// (an executor names its CTM only as an immutable, so without it that binding is unverified,
    /// which the verifier reports as an error rather than comparing the read value with itself).
    pub(crate) reported_ctm: Option<Address>,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin` — likewise for the executor's
    /// `CTM_PROXY_ADMIN`.
    pub(crate) reported_ctm_proxy_admin: Option<Address>,
    /// The ecosystem's Bridgehub and the CTM domain's singletons as the prepares report them. The
    /// Bridgehub is where the ecosystem inventory's slots are discovered when the package names no
    /// CTM to read it from.
    pub(crate) reported_singletons: ReportedSingletons,
    /// `[governance_calls] calls` — the one bundle governance signs.
    pub(crate) calls: Vec<GovernanceCall>,
    /// The prepare's declared external actions — the calls no leg describes.
    pub(crate) external_actions: Vec<ExternalAction>,
    /// Every CREATE2 salt the package records; see [`BootstrapPackage::create2_salts`].
    pub(crate) create2_salts: Vec<B256>,
    /// The package's record of the lifecycle objects' binding values.
    pub(crate) lifecycle: LifecycleInputs,
    /// `[ctms.*.contracts_config] force_deployments_data` — the blob the prepare pinned in the
    /// release the transition installs.
    pub(crate) force_deployments_data: Option<Bytes>,
    /// The executor records the package carries, plus any `--executor-record` the reviewer added
    /// (see [`super::records`]).
    pub(crate) executor_records: UpgradeExecutorsRecord,
    /// The `[member_deployments]` records of the package's prepares (see [`super::records`]).
    pub(crate) member_records: MemberDeployments,
}

impl UpgradePackage {
    fn load(
        ecosystem_toml: &Path,
        root: &toml::Value,
        calls: Vec<GovernanceCall>,
        legs: Vec<RecoveredLeg>,
    ) -> anyhow::Result<Self> {
        let ctm_key = if legs.iter().any(|leg| leg.kind.is_ctm()) {
            Some(sole_ctm_key(root)?)
        } else {
            optional_ctm_key(root)?
        };
        let ctm_registry = |key: &str| {
            ctm_key
                .as_deref()
                .and_then(|ctm| registry_address(root, ctm, key))
        };
        let ctm_section = |section: &str, key: &str| {
            ctm_key
                .as_deref()
                .and_then(|ctm| ctm_address(root, ctm, section, key))
        };
        let lifecycle = lifecycle_inputs_in(root);
        let package = Self {
            reported_core_transition: address_at(
                root,
                &["core", "registry", "core_transition_addr"],
            )
            .filter(|a| !a.is_zero()),
            reported_infrastructure_transition: ctm_registry("ctm_infrastructure_transition_addr"),
            reported_ctm_transition: ctm_registry("ctm_transition_addr"),
            reported_ctm_executor: ctm_registry("ctm_upgrade_executor_addr"),
            reported_ctm: ctm_section("state_transition", "chain_type_manager_proxy"),
            reported_ctm_proxy_admin: ctm_section("deployed_addresses", "transparent_proxy_admin"),
            reported_singletons: ReportedSingletons::in_package(root, ctm_key.as_deref()),
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, ctm_key.as_deref()),
            force_deployments_data: ctm_key
                .as_deref()
                .and_then(|ctm| force_deployments_data_in(root, ctm)),
            executor_records: records_in(root, &ecosystem_toml.display().to_string())?,
            member_records: member_records_in(root, &ecosystem_toml.display().to_string())?,
            lifecycle,
            ctm_key,
            calls,
            legs,
        };
        package.reconcile()?;
        Ok(package)
    }

    /// The leg of `kind`, if the bundle carries one.
    pub(crate) fn leg(&self, kind: LegKind) -> Option<&RecoveredLeg> {
        self.legs.iter().find(|leg| leg.kind == kind)
    }

    /// The object the prepare summary reports for `kind`'s leg.
    pub(crate) fn reported_object(&self, kind: LegKind) -> Option<Address> {
        match kind {
            LegKind::Core => self.reported_core_transition,
            LegKind::Infrastructure => self.reported_infrastructure_transition,
            LegKind::Transition => self.reported_ctm_transition,
        }
    }

    /// The executor the prepare summary reports for `kind`'s leg.
    pub(crate) fn reported_executor(&self, kind: LegKind) -> Option<Address> {
        if kind.is_ctm() {
            self.reported_ctm_executor
        } else {
            self.lifecycle.core_executor
        }
    }

    /// Every leg against its summary, both ways: a reported object must have its leg (a missing
    /// leg leaves a reviewed object unapplied), a leg must have its reported object, and both must
    /// name the same object and executor. Then no call may reach an executor other than through
    /// its legs.
    fn reconcile(&self) -> anyhow::Result<()> {
        for kind in LegKind::CANONICAL_ORDER {
            let field = kind.summary_field();
            let entrypoint = kind.entrypoint();
            match (self.leg(kind), self.reported_object(kind)) {
                (Some(leg), Some(reported)) if reported == leg.object => {}
                (Some(leg), Some(reported)) => anyhow::bail!(
                    "substituted object: the package reports {field} {reported}, but the \
                     bundle's {entrypoint} (call {}) applies {}: the summary a reviewer reads \
                     names a different object from the one governance would apply",
                    leg.index,
                    leg.object
                ),
                (Some(leg), None) => anyhow::bail!(
                    "the bundle's {entrypoint} (call {}) applies {}, but the package reports no \
                     {field}: a leg no prepare summary accounts for",
                    leg.index,
                    leg.object
                ),
                (None, Some(reported)) => anyhow::bail!(
                    "missing leg: the package reports {field} {reported}, but the bundle never \
                     calls {entrypoint}, so the reviewed object would not be applied"
                ),
                (None, None) => {}
            }
        }
        for leg in &self.legs {
            let field = leg.kind.executor_field();
            match self.reported_executor(leg.kind) {
                Some(reported) if reported == leg.executor => {}
                Some(reported) => anyhow::bail!(
                    "substituted executor: the bundle sends {} (call {}) to {}, but the package \
                     reports {field} {reported}",
                    leg.kind.entrypoint(),
                    leg.index,
                    leg.executor
                ),
                None => anyhow::bail!(
                    "the bundle sends {} (call {}) to {}, but the package reports no {field}: the \
                     executor is held against nothing the prepare reported",
                    leg.kind.entrypoint(),
                    leg.index,
                    leg.executor
                ),
            }
        }
        let executors: Vec<Address> = self
            .legs
            .iter()
            .map(|leg| leg.executor)
            .chain(self.lifecycle.core_executor)
            .chain(self.reported_ctm_executor)
            .collect();
        for (index, call) in self.calls.iter().enumerate() {
            if !executors.contains(&call.target) || self.legs.iter().any(|leg| leg.index == index) {
                continue;
            }
            anyhow::bail!(
                "unknown selector on an executor: call {index} reaches the executor {} with \
                 selector 0x{}, which is none of the entrypoints an upgrade drives \
                 (applyL1Upgrade, applyInfrastructureUpgrade, applyCTMUpgrade). An executor \
                 takes exactly the upgrade's legs, so any other call to one — a `forward`, a \
                 nomination — is authority the review never saw",
                call.target,
                alloy::hex::encode(call.data.get(..4).unwrap_or_default())
            );
        }
        Ok(())
    }
}

/// The package's record of the values the lifecycle objects — the two domain executors — were
/// constructed over. Those objects set their bindings as constructor immutables, so their
/// construction is the only identity check they get, and the executors' recorded bindings are
/// held against THESE values (plus the bootstrap manifest) rather than against the objects' own
/// answers.
///
/// Each is optional at load so the report can name exactly which one an older package lacks;
/// the construction check ERRORS on a missing one rather than skipping the object.
#[derive(Debug, Default)]
pub(crate) struct LifecycleInputs {
    /// `[core.registry] core_upgrade_executor_addr` — the ecosystem domain's executor.
    pub(crate) core_executor: Option<Address>,
    /// `[core.upgrade_addresses.shared] transparent_proxy_admin` — the ecosystem `ProxyAdmin`
    /// the core executor was built over.
    pub(crate) core_proxy_admin: Option<Address>,
}

/// The ecosystem's Bridgehub and the CTM domain's singleton proxies as the prepares report them —
/// the last fallbacks a new `ChainTypeManager` implementation's immutables are held against.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct ReportedSingletons {
    /// `[core.upgrade_addresses.bridgehub] bridgehub_proxy_addr`.
    pub(crate) bridgehub: Option<Address>,
    /// `[ctms.*.state_transition] bytecodes_supplier_addr`.
    pub(crate) bytecodes_supplier: Option<Address>,
    /// `[ctms.*.state_transition] permissionless_validator_addr`.
    pub(crate) permissionless_validator: Option<Address>,
    /// `[ctms.*.state_transition] interop_fee_manager_proxy_addr`.
    pub(crate) interop_fee_manager: Option<Address>,
}

impl ReportedSingletons {
    fn in_package(root: &toml::Value, ctm_key: Option<&str>) -> Self {
        let state_transition =
            |key: &str| ctm_key.and_then(|ctm| ctm_address(root, ctm, "state_transition", key));
        Self {
            bridgehub: address_at(
                root,
                &[
                    "core",
                    "upgrade_addresses",
                    "bridgehub",
                    "bridgehub_proxy_addr",
                ],
            )
            .filter(|a| !a.is_zero()),
            bytecodes_supplier: state_transition("bytecodes_supplier_addr"),
            permissionless_validator: state_transition("permissionless_validator_addr"),
            interop_fee_manager: state_transition("interop_fee_manager_proxy_addr"),
        }
    }
}

fn lifecycle_inputs_in(root: &toml::Value) -> LifecycleInputs {
    LifecycleInputs {
        core_executor: address_at(root, &["core", "registry", "core_upgrade_executor_addr"])
            .filter(|a| !a.is_zero()),
        core_proxy_admin: address_at(
            root,
            &[
                "core",
                "upgrade_addresses",
                "shared",
                "transparent_proxy_admin",
            ],
        )
        .filter(|a| !a.is_zero()),
    }
}

#[derive(Debug)]
pub(crate) struct BootstrapPackage {
    /// Objects the prepare names outright.
    pub(crate) core_transition: Option<Address>,
    pub(crate) release: Address,
    /// Recovered from the bundle's `migrate()` call — the executable source of truth.
    pub(crate) migration: Address,
    /// `[registry] bootstrap_migration_addr`, when the prepare named it: a cross-check on the
    /// address recovered from calldata.
    pub(crate) reported_migration: Option<Address>,
    /// `[ctms.*.registry] ctm_upgrade_executor_addr`, a cross-check on the manifest's executor.
    pub(crate) reported_ctm_executor: Option<Address>,
    /// `[ctms.*.state_transition] chain_type_manager_proxy`, a cross-check on the manifest's CTM.
    pub(crate) reported_ctm: Option<Address>,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin`, a cross-check on the manifest's
    /// CTM-domain ProxyAdmin.
    pub(crate) reported_ctm_proxy_admin: Option<Address>,
    /// See [`UpgradePackage::reported_singletons`].
    pub(crate) reported_singletons: ReportedSingletons,
    /// The CTM key under `[ctms]` this package upgrades (e.g. `zksync_os`).
    pub(crate) ctm_key: String,
    /// `[governance_calls] calls` — the one bundle governance signs.
    pub(crate) calls: Vec<GovernanceCall>,
    /// The prepare's declared external actions — calls the objects do NOT describe.
    pub(crate) external_actions: Vec<ExternalAction>,
    /// The package's record of the lifecycle objects' binding values.
    pub(crate) lifecycle: LifecycleInputs,
    /// Every CREATE2 salt the package records, in the order they were found. A prepare deploys
    /// the core leg under the ecosystem salt and each CTM leg under that CTM's, so an object's
    /// address is re-derivable under one of them — which one is reported rather than assumed.
    /// Empty for a package produced before the prepare recorded them, in which case the reviewer
    /// supplies the reviewed salts on the command line.
    pub(crate) create2_salts: Vec<B256>,
    /// `[ctms.*.contracts_config] force_deployments_data` — the blob the prepare pinned in the
    /// release the edge installs.
    pub(crate) force_deployments_data: Option<Bytes>,
    /// The executor records the package carries (the v35 prepares record the executors they
    /// deploy), plus any `--executor-record` the reviewer added.
    pub(crate) executor_records: UpgradeExecutorsRecord,
    /// See [`UpgradePackage::member_records`].
    pub(crate) member_records: MemberDeployments,
}

fn read_toml(ecosystem_toml: &Path) -> anyhow::Result<toml::Value> {
    let raw = std::fs::read_to_string(ecosystem_toml)
        .with_context(|| format!("reading {}", ecosystem_toml.display()))?;
    toml::from_str(&raw).with_context(|| format!("parsing {} as TOML", ecosystem_toml.display()))
}

fn table<'a>(root: &'a toml::Value, path: &[&str]) -> Option<&'a toml::Value> {
    let mut cur = root;
    for key in path {
        cur = cur.get(key)?;
    }
    Some(cur)
}

fn address_at(root: &toml::Value, path: &[&str]) -> Option<Address> {
    table(root, path)?.as_str()?.parse().ok()
}

/// A `uint256` the prepare wrote with `vm.serializeUint` (a TOML integer), or one a hand-edited
/// package carries as a decimal or `0x` string.
fn u256_at(root: &toml::Value, path: &[&str]) -> Option<U256> {
    match table(root, path)? {
        toml::Value::Integer(value) => u64::try_from(*value).ok().map(U256::from),
        toml::Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

/// Collects the CREATE2 salts a merged prepare output records, de-duplicated and order-stable.
///
/// Salt-bearing keys are looked up rather than required: the verifier must keep working against
/// packages produced before the prepare wrote them, where the reviewer supplies the salts
/// instead (and the construction check ERRORS when neither source has any).
fn create2_salts_in(root: &toml::Value, ctm_key: Option<&str>) -> Vec<B256> {
    let mut candidates = vec![
        vec!["misc", "create2_factory_salt"],
        vec!["core", "create2_factory_salt"],
    ];
    if let Some(ctm_key) = ctm_key {
        candidates.push(vec!["ctms", ctm_key, "create2_factory_salt"]);
    }
    let mut salts: Vec<B256> = Vec::new();
    for path in &candidates {
        let Some(parsed) = table(root, path)
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse::<B256>().ok())
        else {
            continue;
        };
        if !salts.contains(&parsed) {
            salts.push(parsed);
        }
    }
    salts
}

/// The package's one governance bundle, `[governance_calls] calls`. A table carrying any other
/// key (the per-stage keys of a pre-collapse package) is refused.
fn bundle_in(root: &toml::Value) -> anyhow::Result<Vec<GovernanceCall>> {
    let table: GovernanceCallsTable = table(root, &["governance_calls"])
        .context("[governance_calls] missing from the package")?
        .clone()
        .try_into()
        .context("[governance_calls] must hold exactly one key, `calls`")?;
    decode_calls(&table.calls).context("[governance_calls] calls does not decode as Call[]")
}

fn external_actions_in(root: &toml::Value) -> anyhow::Result<Vec<ExternalAction>> {
    match table(root, &["external_actions"]) {
        Some(value) => value
            .clone()
            .try_into()
            .context("`external_actions` does not decode as a list of declared actions"),
        None => Ok(Vec::new()),
    }
}

/// The force-deployments blob the CTM prepare wrote with `vm.serializeBytes` (a `0x` string).
fn force_deployments_data_in(root: &toml::Value, ctm_key: &str) -> Option<Bytes> {
    table(
        root,
        &[
            "ctms",
            ctm_key,
            "contracts_config",
            "force_deployments_data",
        ],
    )?
    .as_str()?
    .parse()
    .ok()
}

fn ctm_address(root: &toml::Value, ctm_key: &str, section: &str, key: &str) -> Option<Address> {
    address_at(root, &["ctms", ctm_key, section, key]).filter(|a| !a.is_zero())
}

fn registry_address(root: &toml::Value, ctm_key: &str, key: &str) -> Option<Address> {
    ctm_address(root, ctm_key, "registry", key)
}

/// The single `[ctms.*]` section a package may carry.
///
/// Every kind of package is single-CTM by construction — the prepare boundary admits one ZKsync
/// OS CTM, and the package verifier permits one reviewed CTM executor — so more than one section
/// means the verifier would be reading one upgrade's objects while reporting on another's.
fn sole_ctm_key(root: &toml::Value) -> anyhow::Result<String> {
    optional_ctm_key(root)?.context(
        "[ctms] missing from the package or empty, though it drives the CTM domain — is this a \
         merged prepare output?",
    )
}

/// The `[ctms.*]` section, when the package carries one: absent or empty is `None`, more than one
/// is refused (see [`sole_ctm_key`]).
fn optional_ctm_key(root: &toml::Value) -> anyhow::Result<Option<String>> {
    let Some(ctms) = table(root, &["ctms"]).and_then(|v| v.as_table()) else {
        return Ok(None);
    };
    match ctms.len() {
        0 => Ok(None),
        1 => Ok(ctms.keys().next().cloned()),
        n => anyhow::bail!(
            "expected exactly one [ctms.*] section, found {n}: {:?}",
            ctms.keys().collect::<Vec<_>>()
        ),
    }
}

/// A nonzero object the summary reports for a leg a bootstrap or a replacement does not carry:
/// the merge derives no leg for either kind, so such an object would be deployed and reviewed but
/// never applied — refused rather than reported beside a passing review.
fn refuse_unapplied_objects(
    kind: &str,
    reported: &[(&str, Option<Address>)],
) -> anyhow::Result<()> {
    for (field, object) in reported {
        if let Some(object) = object {
            anyhow::bail!(
                "missing leg: the package reports {field} {object}, but a {kind} package carries \
                 no executor leg to apply it"
            );
        }
    }
    Ok(())
}

impl BootstrapPackage {
    fn load(
        ecosystem_toml: &Path,
        root: &toml::Value,
        calls: Vec<GovernanceCall>,
    ) -> anyhow::Result<Self> {
        let migration = sole_migrate_target(&calls)?;

        let ctm_key = sole_ctm_key(root)?;
        // The edge installs its release through the migration and its core transition through
        // the derived sequence; a CTM-domain object beside them would never be applied.
        refuse_unapplied_objects(
            "bootstrap",
            &[
                (
                    "ctm_infrastructure_transition_addr",
                    registry_address(root, &ctm_key, "ctm_infrastructure_transition_addr"),
                ),
                (
                    "ctm_transition_addr",
                    registry_address(root, &ctm_key, "ctm_transition_addr"),
                ),
            ],
        )?;
        let release = registry_address(root, &ctm_key, "ctm_release_addr")
            .context("[ctms.*.registry] ctm_release_addr missing, zero or unparsable")?;
        // The core leg is optional: a CTM-only edge deploys no ecosystem implementations, so
        // the prepare pins no Core-domain `ProxyUpgradeTransition` (an all-inert inventory is
        // refused at construction).
        let core_transition = address_at(root, &["core", "registry", "core_transition_addr"])
            .filter(|a| !a.is_zero());

        Ok(Self {
            core_transition,
            release,
            migration,
            reported_migration: registry_address(root, &ctm_key, "bootstrap_migration_addr"),
            reported_ctm_executor: registry_address(root, &ctm_key, "ctm_upgrade_executor_addr"),
            reported_ctm: ctm_address(
                root,
                &ctm_key,
                "state_transition",
                "chain_type_manager_proxy",
            ),
            reported_ctm_proxy_admin: ctm_address(
                root,
                &ctm_key,
                "deployed_addresses",
                "transparent_proxy_admin",
            ),
            reported_singletons: ReportedSingletons::in_package(root, Some(&ctm_key)),
            calls,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, Some(&ctm_key)),
            lifecycle: lifecycle_inputs_in(root),
            force_deployments_data: force_deployments_data_in(root, &ctm_key),
            executor_records: records_in(root, &ecosystem_toml.display().to_string())?,
            member_records: member_records_in(root, &ecosystem_toml.display().to_string())?,
            ctm_key,
        })
    }
}

/// Every target the bundle calls `migrate()` on — the bootstrap migrations it drives.
fn migrate_targets(calls: &[GovernanceCall]) -> Vec<Address> {
    calls
        .iter()
        .filter(|c| c.data.len() == 4 && c.data[..4] == MIGRATE_SELECTOR)
        .map(|c| c.target)
        .collect()
}

/// The migration is whatever the bundle calls `migrate()` on — and there must be exactly one such
/// call, or the package drives more than one bootstrap edge in a single bundle.
fn sole_migrate_target(calls: &[GovernanceCall]) -> anyhow::Result<Address> {
    match migrate_targets(calls).as_slice() {
        [one] => Ok(*one),
        [] => anyhow::bail!(
            "the governance bundle contains no `migrate()` call, so it drives no bootstrap edge"
        ),
        many => anyhow::bail!(
            "the governance bundle calls `migrate()` on {} objects ({many:?}); a bootstrap \
             package must drive exactly one edge",
            many.len()
        ),
    }
}

/// A replacement of a committed transition: one `CTMUpgradeExecutor.forward` carrying
/// `ChainTypeManager.replaceUpgradeTransition(expected, replacement)`, optionally followed by
/// `setProtocolVersionDeadline`. Its prepare deploys the replacement alone — no release (it lands
/// on an existing one), no executor, and no object an executor leg would apply.
#[derive(Debug)]
pub(crate) struct ReplacementPackage {
    /// The forward call, recovered from the calldata — the executable source of truth.
    pub(crate) forward: RecoveredReplacement,
    /// The CTM key under `[ctms]` this package names (e.g. `zksync_os`).
    pub(crate) ctm_key: String,
    /// `[ctms.*.registry] replaced_transition_addr`, a cross-check on the recovered `expected`.
    pub(crate) reported_replaced: Option<Address>,
    /// `[ctms.*.registry] replacement_transition_addr`, a cross-check on the recovered replacement.
    pub(crate) reported_replacement: Option<Address>,
    /// `[ctms.*.registry] ctm_transition_addr` — the prepare's transition, i.e. the replacement.
    pub(crate) reported_ctm_transition: Option<Address>,
    /// `[ctms.*.registry] ctm_release_addr` — the replacement's arriving release.
    pub(crate) reported_release: Option<Address>,
    /// `[ctms.*.registry] ctm_upgrade_executor_addr`, a cross-check on the forward's target.
    pub(crate) reported_ctm_executor: Option<Address>,
    /// `[ctms.*.state_transition] chain_type_manager_proxy`, a cross-check on the inner target and
    /// the value the CTM executor's `CHAIN_TYPE_MANAGER` is held against.
    pub(crate) reported_ctm: Option<Address>,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin` — the CTM executor's
    /// `CTM_PROXY_ADMIN` is held against it.
    pub(crate) reported_ctm_proxy_admin: Option<Address>,
    /// `[governance_calls] calls` — the one bundle governance signs.
    pub(crate) calls: Vec<GovernanceCall>,
    /// The prepare's declared external actions (the forward is one of them).
    pub(crate) external_actions: Vec<ExternalAction>,
    /// Every CREATE2 salt the package records; see [`BootstrapPackage::create2_salts`].
    pub(crate) create2_salts: Vec<B256>,
    /// `[ctms.*.contracts_config] old_protocol_version` — the replaced transition's departing
    /// version, a cross-check.
    pub(crate) reported_old_version: Option<U256>,
    /// `[ctms.*.contracts_config] new_protocol_version` — the replacement's target, a cross-check.
    pub(crate) reported_new_version: Option<U256>,
    /// The executor records the reviewer added with `--executor-record` (the prepare deploys no
    /// executor, so the package itself normally carries none).
    pub(crate) executor_records: UpgradeExecutorsRecord,
    /// See [`UpgradePackage::member_records`]: the replacement's engine is the prepare's.
    pub(crate) member_records: MemberDeployments,
}

impl ReplacementPackage {
    fn load(
        ecosystem_toml: &Path,
        root: &toml::Value,
        forward: RecoveredReplacement,
        calls: Vec<GovernanceCall>,
    ) -> anyhow::Result<Self> {
        let ctm_key = sole_ctm_key(root)?;
        // A replacement repairs one committed edge through `forward`; an ecosystem or
        // infrastructure object beside it would be deployed and never applied.
        refuse_unapplied_objects(
            "replacement",
            &[
                (
                    "core_transition_addr",
                    address_at(root, &["core", "registry", "core_transition_addr"])
                        .filter(|a| !a.is_zero()),
                ),
                (
                    "ctm_infrastructure_transition_addr",
                    registry_address(root, &ctm_key, "ctm_infrastructure_transition_addr"),
                ),
            ],
        )?;
        Ok(Self {
            forward,
            reported_replaced: registry_address(root, &ctm_key, "replaced_transition_addr"),
            reported_replacement: registry_address(root, &ctm_key, "replacement_transition_addr"),
            reported_ctm_transition: registry_address(root, &ctm_key, "ctm_transition_addr"),
            reported_release: registry_address(root, &ctm_key, "ctm_release_addr"),
            reported_ctm_executor: registry_address(root, &ctm_key, "ctm_upgrade_executor_addr"),
            reported_ctm: ctm_address(
                root,
                &ctm_key,
                "state_transition",
                "chain_type_manager_proxy",
            ),
            reported_ctm_proxy_admin: ctm_address(
                root,
                &ctm_key,
                "deployed_addresses",
                "transparent_proxy_admin",
            ),
            calls,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, Some(&ctm_key)),
            reported_old_version: u256_at(
                root,
                &["ctms", &ctm_key, "contracts_config", "old_protocol_version"],
            ),
            reported_new_version: u256_at(
                root,
                &["ctms", &ctm_key, "contracts_config", "new_protocol_version"],
            ),
            executor_records: records_in(root, &ecosystem_toml.display().to_string())?,
            member_records: member_records_in(root, &ecosystem_toml.display().to_string())?,
            ctm_key,
        })
    }
}

/// The replacement as the calldata states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RecoveredReplacement {
    /// The forward's index in the bundle.
    pub(crate) index: usize,
    /// The forward's target: the verifier requires it to be the CTM's executor.
    pub(crate) executor: Address,
    /// The inner calls' one target: the verifier requires it to be the CTM.
    pub(crate) ctm: Address,
    pub(crate) expected: Address,
    pub(crate) replacement: Address,
    /// The `setProtocolVersionDeadline` riding the same forward, if any.
    pub(crate) deadline: Option<DeadlineChange>,
}

/// `ChainTypeManager.setProtocolVersionDeadline(protocol_version, timestamp)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DeadlineChange {
    pub(crate) protocol_version: U256,
    pub(crate) timestamp: U256,
}

/// The `forward` that replaces a transition, if any call of the bundle is one.
///
/// A forward counts when one of its inner calls has `replaceUpgradeTransition`'s selector; it must
/// then be exactly `[replaceUpgradeTransition]` or `[replaceUpgradeTransition,
/// setProtocolVersionDeadline]` on one target, carrying no value — anything else in it is
/// refused, since this tool would otherwise verify the replacement and wave the rest through.
pub(crate) fn recover_replacement(
    calls: &[GovernanceCall],
) -> anyhow::Result<Option<RecoveredReplacement>> {
    use super::views::{CTMUpgradeExecutorView, CtmView};
    use alloy::sol_types::SolCall;

    let replace_selector = CtmView::replaceUpgradeTransitionCall::SELECTOR;
    let mut found: Option<RecoveredReplacement> = None;
    for (index, call) in calls.iter().enumerate() {
        if call.data.get(..4) != Some(&CTMUpgradeExecutorView::forwardCall::SELECTOR[..]) {
            continue;
        }
        let Ok(forward) = CTMUpgradeExecutorView::forwardCall::abi_decode(&call.data) else {
            continue;
        };
        let inner = forward._calls;
        if !inner
            .iter()
            .any(|c| c.data.get(..4) == Some(&replace_selector[..]))
        {
            continue;
        }
        anyhow::ensure!(
            found.is_none(),
            "more than one `forward` replaces a transition (call {index}, and an earlier one): \
             a replacement package replaces exactly one"
        );
        anyhow::ensure!(
            call.value.is_zero() && inner.iter().all(|c| c.value.is_zero()),
            "the `forward` that replaces a transition (call {index}) carries value; a \
             replacement moves none"
        );
        let shape = |why: &str| {
            anyhow::anyhow!(
                "the `forward` that replaces a transition (call {index}) {why}: \
                 it must carry exactly `replaceUpgradeTransition(expected, replacement)`, \
                 optionally followed by `setProtocolVersionDeadline`, on the CTM — anything \
                 else in it is refused"
            )
        };
        let replace = inner
            .first()
            .and_then(|c| CtmView::replaceUpgradeTransitionCall::abi_decode(&c.data).ok())
            .ok_or_else(|| shape("does not start with `replaceUpgradeTransition`"))?;
        let deadline = match inner.get(1) {
            None => None,
            Some(c) => {
                let call =
                    CtmView::setProtocolVersionDeadlineCall::abi_decode(&c.data).map_err(|_| {
                        shape("carries a second call that is not `setProtocolVersionDeadline`")
                    })?;
                Some(DeadlineChange {
                    protocol_version: call._protocolVersion,
                    timestamp: call._timestamp,
                })
            }
        };
        if inner.len() > 2 {
            return Err(shape(&format!("carries {} calls", inner.len())));
        }
        let ctm = inner[0].target;
        if inner.iter().any(|c| c.target != ctm) {
            return Err(shape("addresses more than one target"));
        }
        found = Some(RecoveredReplacement {
            index,
            executor: call.target,
            ctm,
            expected: replace._expectedTransition,
            replacement: replace._replacement,
            deadline,
        });
    }
    Ok(found)
}

#[cfg(test)]
mod tests;
