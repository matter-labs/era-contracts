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
mod tests {
    use super::*;
    use alloy::primitives::U256;

    fn call(target: Address, data: Vec<u8>) -> GovernanceCall {
        GovernanceCall {
            target,
            value: U256::ZERO,
            data,
        }
    }

    #[test]
    fn migrate_selector_matches_the_solidity_signature() {
        // Guards the hardcoded constant against a signature change.
        let computed = alloy::primitives::keccak256(b"migrate()");
        assert_eq!(&computed[..4], &MIGRATE_SELECTOR);
    }

    #[test]
    fn transfer_ownership_selector_matches_the_solidity_signature() {
        let computed = alloy::primitives::keccak256(b"transferOwnership(address)");
        assert_eq!(&computed[..4], &TRANSFER_OWNERSHIP_SELECTOR);
    }

    /// The three entrypoints a leg is recognized by must be the executors' real ones, so a
    /// signature change is caught here rather than by a package whose legs silently stop being
    /// recognized. Transcribed (from the compiled artifacts' `methodIdentifiers`) as well as
    /// derived, so the `sol!` mirror cannot drift with them.
    #[test]
    fn the_leg_selectors_are_the_executors() {
        for (kind, signature, transcribed) in [
            (
                LegKind::Core,
                "applyL1Upgrade(address)",
                [0x60, 0x93, 0xa2, 0x59],
            ),
            (
                LegKind::Infrastructure,
                "applyInfrastructureUpgrade(address)",
                [0x68, 0xe9, 0x89, 0x78],
            ),
            (
                LegKind::Transition,
                "applyCTMUpgrade(address)",
                [0x7b, 0x1b, 0x71, 0x6a],
            ),
        ] {
            assert_eq!(kind.selector(), transcribed, "{signature}");
            assert_eq!(
                &alloy::primitives::keccak256(signature.as_bytes())[..4],
                &transcribed,
                "{signature}"
            );
            let encoded = kind.encode(Address::repeat_byte(0x0b));
            assert_eq!(encoded.len(), 4 + 32);
            assert_eq!(kind.decode(&encoded), Some(Address::repeat_byte(0x0b)));
        }
    }

    #[test]
    fn the_canonical_order_is_core_infrastructure_transition() {
        assert_eq!(
            LegKind::CANONICAL_ORDER,
            [LegKind::Core, LegKind::Infrastructure, LegKind::Transition]
        );
        assert!(LegKind::Core < LegKind::Infrastructure);
        assert!(LegKind::Infrastructure < LegKind::Transition);
    }

    #[test]
    fn recovers_the_migration_from_the_bundle() {
        let migration = Address::repeat_byte(0xAB);
        let bundle = vec![
            call(
                Address::repeat_byte(0x11),
                TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
            ),
            call(migration, MIGRATE_SELECTOR.to_vec()),
        ];
        assert_eq!(sole_migrate_target(&bundle).unwrap(), migration);
    }

    #[test]
    fn rejects_a_package_with_no_migrate_call() {
        let bundle = vec![call(
            Address::repeat_byte(0x11),
            vec![0xde, 0xad, 0xbe, 0xef],
        )];
        let err = sole_migrate_target(&bundle).unwrap_err().to_string();
        assert!(err.contains("no `migrate()` call"), "{err}");
    }

    #[test]
    fn rejects_a_package_driving_two_edges() {
        let bundle = vec![
            call(Address::repeat_byte(0xAA), MIGRATE_SELECTOR.to_vec()),
            call(Address::repeat_byte(0xBB), MIGRATE_SELECTOR.to_vec()),
        ];
        let err = sole_migrate_target(&bundle).unwrap_err().to_string();
        assert!(err.contains("exactly one edge"), "{err}");
    }

    // ───────────────────────── upgrade packages ─────────────────────────
    //
    // A merged prepare output in the exact shape `write_merged_ecosystem_toml` emits — the core
    // and CTM prepares' summaries and the legs the merge derived from them, as real ABI-encoded
    // `Call[]` hex — so the loader is driven through the same entry point production uses.

    const CORE_EXECUTOR: Address = Address::repeat_byte(0xE0);
    const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);
    const CORE_TRANSITION: Address = Address::repeat_byte(0xEE);
    const INFRASTRUCTURE: Address = Address::repeat_byte(0x1F);
    const TRANSITION: Address = Address::repeat_byte(0xCC);
    const RELEASE: Address = Address::repeat_byte(0xC1);
    const CTM_PROXY: Address = Address::repeat_byte(0xF1);
    const CTM_ADMIN: Address = Address::repeat_byte(0xF2);
    const ECO_ADMIN: Address = Address::repeat_byte(0xE2);
    const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
    const STRANGER: Address = Address::repeat_byte(0x99);

    fn leg(kind: LegKind, executor: Address, object: Address) -> GovernanceCall {
        call(executor, kind.encode(object))
    }

    fn core_leg() -> GovernanceCall {
        leg(LegKind::Core, CORE_EXECUTOR, CORE_TRANSITION)
    }

    fn infrastructure_leg() -> GovernanceCall {
        leg(LegKind::Infrastructure, CTM_EXECUTOR, INFRASTRUCTURE)
    }

    fn transition_leg() -> GovernanceCall {
        leg(LegKind::Transition, CTM_EXECUTOR, TRANSITION)
    }

    /// The prepares' summaries of what they deployed: zero for an object a prepare did not deploy.
    #[derive(Clone)]
    struct Summary {
        core_transition: Address,
        infrastructure: Address,
        transition: Address,
        bootstrap_migration: Address,
        ctm_section: bool,
    }

    impl Summary {
        fn all() -> Self {
            Self {
                core_transition: CORE_TRANSITION,
                infrastructure: INFRASTRUCTURE,
                transition: TRANSITION,
                bootstrap_migration: Address::ZERO,
                ctm_section: true,
            }
        }

        fn of(core: bool, infrastructure: bool, transition: bool) -> Self {
            let pick = |on: bool, object: Address| if on { object } else { Address::ZERO };
            Self {
                core_transition: pick(core, CORE_TRANSITION),
                infrastructure: pick(infrastructure, INFRASTRUCTURE),
                transition: pick(transition, TRANSITION),
                ..Self::all()
            }
        }

        fn toml(&self, calls: &[GovernanceCall]) -> String {
            let mut body = format!(
                "[core]\n\
                 create2_factory_salt = \"{}\"\n\
                 [core.registry]\n\
                 core_transition_addr = \"{}\"\n\
                 core_upgrade_executor_addr = \"{CORE_EXECUTOR}\"\n\
                 [core.upgrade_addresses.shared]\n\
                 transparent_proxy_admin = \"{ECO_ADMIN}\"\n\
                 [core.upgrade_addresses.bridgehub]\n\
                 bridgehub_proxy_addr = \"{BRIDGEHUB}\"\n",
                B256::repeat_byte(0x5A),
                self.core_transition,
            );
            if self.ctm_section {
                body.push_str(&format!(
                    "[ctms.zksync_os]\n\
                     create2_factory_salt = \"{}\"\n\
                     [ctms.zksync_os.registry]\n\
                     ctm_transition_addr = \"{}\"\n\
                     ctm_infrastructure_transition_addr = \"{}\"\n\
                     ctm_release_addr = \"{RELEASE}\"\n\
                     bootstrap_migration_addr = \"{}\"\n\
                     ctm_upgrade_executor_addr = \"{CTM_EXECUTOR}\"\n\
                     [ctms.zksync_os.state_transition]\n\
                     chain_type_manager_proxy = \"{CTM_PROXY}\"\n\
                     [ctms.zksync_os.deployed_addresses]\n\
                     transparent_proxy_admin = \"{CTM_ADMIN}\"\n\
                     [ctms.zksync_os.contracts_config]\n\
                     force_deployments_data = \"0xf0f1f2\"\n",
                    B256::repeat_byte(0x6B),
                    self.transition,
                    self.infrastructure,
                    self.bootstrap_migration,
                ));
            }
            body.push_str(&format!(
                "[governance_calls]\ncalls = \"0x{}\"\n",
                alloy::hex::encode(crate::common::governance_calls::encode_calls(calls))
            ));
            body
        }
    }

    fn load_str(body: &str) -> anyhow::Result<RegistryPackage> {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ecosystem.toml");
        std::fs::write(&path, body).unwrap();
        RegistryPackage::load(&path)
    }

    fn load_upgrade(summary: &Summary, calls: &[GovernanceCall]) -> UpgradePackage {
        match load_str(&summary.toml(calls)).expect("the package must load") {
            RegistryPackage::Upgrade(package) => package,
            other => panic!("expected an upgrade package, got {other:?}"),
        }
    }

    fn refusal(summary: &Summary, calls: &[GovernanceCall]) -> String {
        format!(
            "{:#}",
            load_str(&summary.toml(calls)).expect_err("the package must be refused")
        )
    }

    /// The classification is the calldata: executor legs make an upgrade, and every leg is
    /// recovered from the call governance signs — with its executor and object — and reconciled
    /// with the summary that names it.
    #[test]
    fn an_upgrade_package_loads_its_legs_from_the_calldata() {
        let package = load_upgrade(
            &Summary::all(),
            &[core_leg(), infrastructure_leg(), transition_leg()],
        );
        assert_eq!(
            package.legs,
            vec![
                RecoveredLeg {
                    kind: LegKind::Core,
                    index: 0,
                    executor: CORE_EXECUTOR,
                    object: CORE_TRANSITION,
                },
                RecoveredLeg {
                    kind: LegKind::Infrastructure,
                    index: 1,
                    executor: CTM_EXECUTOR,
                    object: INFRASTRUCTURE,
                },
                RecoveredLeg {
                    kind: LegKind::Transition,
                    index: 2,
                    executor: CTM_EXECUTOR,
                    object: TRANSITION,
                },
            ]
        );
        assert_eq!(package.ctm_key.as_deref(), Some("zksync_os"));
        assert_eq!(package.reported_ctm, Some(CTM_PROXY));
        assert_eq!(package.reported_ctm_proxy_admin, Some(CTM_ADMIN));
        assert_eq!(package.reported_singletons.bridgehub, Some(BRIDGEHUB));
        assert_eq!(package.lifecycle.core_executor, Some(CORE_EXECUTOR));
        assert_eq!(package.lifecycle.core_proxy_admin, Some(ECO_ADMIN));
        assert_eq!(
            package.force_deployments_data,
            Some(Bytes::from_static(&[0xf0, 0xf1, 0xf2]))
        );
        assert_eq!(
            package.create2_salts,
            vec![B256::repeat_byte(0x5A), B256::repeat_byte(0x6B)]
        );
    }

    /// Each leg alone is an upgrade of its own — the subsequence of the canonical run.
    #[test]
    fn each_leg_alone_loads_as_an_upgrade() {
        for (summary, call, kind) in [
            (Summary::of(true, false, false), core_leg(), LegKind::Core),
            (
                Summary::of(false, true, false),
                infrastructure_leg(),
                LegKind::Infrastructure,
            ),
            (
                Summary::of(false, false, true),
                transition_leg(),
                LegKind::Transition,
            ),
        ] {
            let package = load_upgrade(&summary, &[call]);
            assert_eq!(package.legs.len(), 1);
            assert_eq!(package.legs[0].kind, kind);
        }
    }

    /// A core-only upgrade needs no CTM prepare: with no `[ctms]` section at all it still loads,
    /// and reads its CTM inputs as absent.
    #[test]
    fn a_core_only_package_needs_no_ctm_section() {
        let summary = Summary {
            ctm_section: false,
            ..Summary::of(true, false, false)
        };
        let package = load_upgrade(&summary, &[core_leg()]);
        assert_eq!(package.ctm_key, None);
        assert_eq!(package.reported_ctm, None);
        assert_eq!(package.force_deployments_data, None);
        assert_eq!(package.create2_salts, vec![B256::repeat_byte(0x5A)]);
    }

    /// A CTM leg without the CTM section cannot be held against the reviewed CTM at all.
    #[test]
    fn a_ctm_leg_requires_the_ctm_section() {
        let summary = Summary {
            ctm_section: false,
            ..Summary::of(false, false, true)
        };
        let err = refusal(&summary, &[transition_leg()]);
        assert!(err.contains("[ctms] missing from the package"), "{err}");
    }

    /// A package that is neither kind must not be verified as the nearest match.
    #[test]
    fn a_package_that_is_neither_kind_is_refused() {
        let err = refusal(&Summary::of(false, false, false), &[]);
        assert!(err.contains("neither kind of package"), "{err}");
        let err = refusal(
            &Summary::of(false, false, false),
            &[call(STRANGER, vec![0xde, 0xad, 0xbe, 0xef])],
        );
        assert!(err.contains("neither kind of package"), "{err}");
    }

    /// The post-replay check asks whether a governance TOML is a registry package at all: one
    /// that is none of the three kinds is `None` there (not refused), while a registry package
    /// still loads — or is refused — exactly as `load` would.
    #[test]
    fn only_a_bundle_of_none_of_the_kinds_is_not_a_registry_package() {
        let load_if = |summary: &Summary, calls: &[GovernanceCall]| {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("ecosystem.toml");
            std::fs::write(&path, summary.toml(calls)).unwrap();
            RegistryPackage::load_if_registry(&path)
        };
        let none = Summary::of(false, false, false);
        assert!(load_if(&none, &[]).unwrap().is_none());
        assert!(
            load_if(&none, &[call(STRANGER, vec![0xde, 0xad, 0xbe, 0xef])])
                .unwrap()
                .is_none()
        );
        assert!(matches!(
            load_if(
                &Summary::all(),
                &[core_leg(), infrastructure_leg(), transition_leg()]
            ),
            Ok(Some(RegistryPackage::Upgrade(_)))
        ));
        let err = load_if(&Summary::all(), &[core_leg()]).expect_err("a missing leg is refused");
        assert!(format!("{err:#}").contains("missing leg"), "{err:#}");
    }

    /// A pre-collapse package — per-stage keys instead of the one `calls` — is refused rather
    /// than read with its calls dropped.
    #[test]
    fn a_package_with_per_stage_keys_is_refused() {
        let body = Summary::all()
            .toml(&[])
            .replace("calls = \"0x", "stage1_calls = \"0x\"\nstage0_calls = \"0x");
        let err = format!("{:#}", load_str(&body).unwrap_err());
        assert!(err.contains("exactly one key"), "{err}");
    }

    /// Q5: the summary names an object the bundle never applies — a reviewed object that would be
    /// left unapplied.
    #[test]
    fn a_missing_leg_is_refused() {
        let err = refusal(&Summary::all(), &[core_leg(), transition_leg()]);
        assert!(err.contains("missing leg"), "{err}");
        assert!(err.contains("ctm_infrastructure_transition_addr"), "{err}");
    }

    /// The other direction: a leg no summary accounts for.
    #[test]
    fn a_leg_without_its_summary_is_refused() {
        let err = refusal(
            &Summary::of(true, false, false),
            &[core_leg(), transition_leg()],
        );
        assert!(err.contains("reports no ctm_transition_addr"), "{err}");
    }

    /// Q5: the bundle applies another object than the one the summary names.
    #[test]
    fn a_substituted_object_is_refused() {
        let err = refusal(
            &Summary::of(false, false, true),
            &[leg(LegKind::Transition, CTM_EXECUTOR, STRANGER)],
        );
        assert!(err.contains("substituted object"), "{err}");
    }

    /// The right object sent to another executor than the summary names — including a core leg
    /// sent to the CTM domain's executor.
    #[test]
    fn a_substituted_executor_is_refused() {
        for bad in [
            leg(LegKind::Core, STRANGER, CORE_TRANSITION),
            leg(LegKind::Core, CTM_EXECUTOR, CORE_TRANSITION),
        ] {
            let err = refusal(&Summary::of(true, false, false), &[bad]);
            assert!(err.contains("substituted executor"), "{err}");
        }
        let err = refusal(
            &Summary::of(false, true, true),
            &[
                infrastructure_leg(),
                leg(LegKind::Transition, STRANGER, TRANSITION),
            ],
        );
        assert!(err.contains("substituted executor"), "{err}");
    }

    /// Q5: a leg twice — the second application is not a bundle the merge produces.
    #[test]
    fn a_duplicated_leg_is_refused() {
        let err = refusal(
            &Summary::of(false, false, true),
            &[transition_leg(), transition_leg()],
        );
        assert!(err.contains("duplicate leg"), "{err}");
    }

    /// The executor entrypoints are not payable, so a leg carrying value is not the derived call.
    #[test]
    fn a_leg_carrying_value_is_refused() {
        let mut paying = core_leg();
        paying.value = U256::from(1);
        let err = refusal(&Summary::of(true, false, false), &[paying]);
        assert!(err.contains("carries value"), "{err}");
    }

    /// A call with a leg's selector but not exactly its calldata is refused rather than read as
    /// the nearest leg.
    #[test]
    fn malformed_leg_calldata_is_refused() {
        let mut trailing = core_leg();
        trailing.data.extend_from_slice(&[0u8; 32]);
        let err = refusal(&Summary::of(true, false, false), &[trailing]);
        assert!(err.contains("not exactly its calldata"), "{err}");

        let mut dirty = core_leg();
        dirty.data[4] = 0xff; // an address word with its high bytes set
        let err = refusal(&Summary::of(true, false, false), &[dirty]);
        assert!(err.contains("not exactly its calldata"), "{err}");
    }

    /// Q5: any call to an executor other than its legs — a `forward`, a nomination — is
    /// authority the review never saw, and is refused whether or not the package declares it.
    #[test]
    fn an_unknown_selector_on_an_executor_is_refused() {
        let nomination = call(
            CTM_EXECUTOR,
            [
                TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
                STRANGER.into_word().to_vec(),
            ]
            .concat(),
        );
        let err = refusal(
            &Summary::of(false, false, true),
            &[transition_leg(), nomination],
        );
        assert!(err.contains("unknown selector on an executor"), "{err}");

        // The core executor is the ecosystem domain's, even when this upgrade has no core leg.
        let forward = call(
            CORE_EXECUTOR,
            CTMUpgradeExecutorView::forwardCall { _calls: Vec::new() }.abi_encode(),
        );
        let err = refusal(
            &Summary::of(false, false, true),
            &[forward, transition_leg()],
        );
        assert!(err.contains("unknown selector on an executor"), "{err}");
    }

    /// Q5 mixed kinds: CTM legs beside a bootstrap's `migrate()`.
    #[test]
    fn upgrade_legs_beside_a_migrate_are_refused() {
        let migration = Address::repeat_byte(0x55);
        let summary = Summary {
            bootstrap_migration: migration,
            ..Summary::of(true, false, false)
        };
        let err = refusal(
            &summary,
            &[
                core_leg(),
                transition_leg(),
                call(migration, MIGRATE_SELECTOR.to_vec()),
            ],
        );
        assert!(err.contains("mixed kinds"), "{err}");
    }

    /// The bootstrap's own sequence applies the core transition — that one leg is the edge's, not
    /// an upgrade beside it, so the package loads as a bootstrap.
    #[test]
    fn the_bootstrap_sequences_core_leg_is_not_a_mixed_kind() {
        let migration = Address::repeat_byte(0x55);
        let summary = Summary {
            bootstrap_migration: migration,
            ..Summary::of(true, false, false)
        };
        let package =
            load_str(&summary.toml(&[core_leg(), call(migration, MIGRATE_SELECTOR.to_vec())]))
                .unwrap();
        let RegistryPackage::Bootstrap(package) = package else {
            panic!("a migrate() bundle is a bootstrap");
        };
        assert_eq!(package.migration, migration);
        assert_eq!(package.core_transition, Some(CORE_TRANSITION));
    }

    /// A bootstrap's summary naming a CTM-domain object: nothing in the edge applies it.
    #[test]
    fn a_bootstrap_reporting_a_ctm_object_is_refused() {
        let migration = Address::repeat_byte(0x55);
        let summary = Summary {
            bootstrap_migration: migration,
            ..Summary::of(true, false, true)
        };
        let err = refusal(&summary, &[call(migration, MIGRATE_SELECTOR.to_vec())]);
        assert!(err.contains("missing leg"), "{err}");
        assert!(err.contains("bootstrap"), "{err}");
    }

    // ───────────────────────── a release the tool has never heard of ─────────────────────────
    //
    // `CTMUpgrade_v36 is DefaultCTMUpgrade {}` — an empty subclass. A v36 upgrade is an ORDINARY
    // registry upgrade, so it must load through the general path with no v36 module, no v36
    // branch and no v36 constant anywhere in this tree. The loader never learns a release name.

    /// A release with no module of its own loads as an ordinary upgrade, and every summary field
    /// the verifier holds the CTM executor's immutables against is picked up.
    #[test]
    fn a_release_with_no_module_of_its_own_loads_as_an_ordinary_upgrade() {
        let package = load_upgrade(&Summary::of(false, false, true), &[transition_leg()]);
        assert_eq!(package.reported_ctm_transition, Some(TRANSITION));
        assert_eq!(package.reported_ctm_executor, Some(CTM_EXECUTOR));
        assert_eq!(package.reported_ctm, Some(CTM_PROXY));
        assert_eq!(package.reported_ctm_proxy_admin, Some(CTM_ADMIN));
    }

    /// The zero `bootstrap_migration_addr` a post-bootstrap release carries must not divert it
    /// into the bootstrap path.
    #[test]
    fn a_zero_bootstrap_field_does_not_divert_an_ordinary_release() {
        let body = Summary::of(false, false, true).toml(&[transition_leg()]);
        assert!(body.contains("bootstrap_migration_addr"));
        assert!(matches!(
            load_str(&body).unwrap(),
            RegistryPackage::Upgrade(_)
        ));
    }

    // ───────────────────────── transition replacements ─────────────────────────

    use super::super::views::{BootstrapCall, CtmView};

    const CTM: Address = Address::repeat_byte(0xC7);
    const EXPECTED: Address = Address::repeat_byte(0x7A);
    const REPLACEMENT: Address = Address::repeat_byte(0x7B);
    const DEPARTURE: u64 = 0x23_0000_0000;

    fn inner(target: Address, data: Vec<u8>) -> BootstrapCall {
        BootstrapCall {
            target,
            value: U256::ZERO,
            data: data.into(),
        }
    }

    fn replace_call() -> BootstrapCall {
        inner(
            CTM,
            CtmView::replaceUpgradeTransitionCall {
                _expectedTransition: EXPECTED,
                _replacement: REPLACEMENT,
            }
            .abi_encode(),
        )
    }

    fn deadline_call(version: u64, timestamp: u64) -> BootstrapCall {
        inner(
            CTM,
            CtmView::setProtocolVersionDeadlineCall {
                _protocolVersion: U256::from(version),
                _timestamp: U256::from(timestamp),
            }
            .abi_encode(),
        )
    }

    fn forward(calls: Vec<BootstrapCall>) -> GovernanceCall {
        call(
            CTM_EXECUTOR,
            CTMUpgradeExecutorView::forwardCall { _calls: calls }.abi_encode(),
        )
    }

    #[test]
    fn recovers_a_replacement_from_its_forward() {
        let recovered = recover_replacement(&[forward(vec![replace_call()])])
            .unwrap()
            .expect("a forward of replaceUpgradeTransition is a replacement");
        assert_eq!(
            recovered,
            RecoveredReplacement {
                index: 0,
                executor: CTM_EXECUTOR,
                ctm: CTM,
                expected: EXPECTED,
                replacement: REPLACEMENT,
                deadline: None,
            }
        );
    }

    #[test]
    fn recovers_the_deadline_call_riding_the_same_forward() {
        let recovered = recover_replacement(&[
            call(Address::repeat_byte(0x11), vec![0xde, 0xad, 0xbe, 0xef]),
            forward(vec![
                replace_call(),
                deadline_call(DEPARTURE, 1_900_000_000),
            ]),
        ])
        .unwrap()
        .unwrap();
        assert_eq!(recovered.index, 1);
        assert_eq!(
            recovered.deadline,
            Some(DeadlineChange {
                protocol_version: U256::from(DEPARTURE),
                timestamp: U256::from(1_900_000_000u64),
            })
        );
    }

    /// The bootstrap's notifier acceptance is a `forward` too; without a replace it is not a
    /// replacement, and a package of only ordinary calls has none.
    #[test]
    fn a_forward_that_replaces_nothing_is_not_a_replacement() {
        let accept = inner(Address::repeat_byte(0x2A), vec![0x79, 0xba, 0x50, 0x97]);
        assert!(recover_replacement(&[forward(vec![accept])])
            .unwrap()
            .is_none());
        assert!(recover_replacement(&[]).unwrap().is_none());
    }

    /// Anything beside the replace and the optional deadline would ride a verified replacement
    /// unverified, so it is refused outright.
    #[test]
    fn a_forward_carrying_anything_else_is_refused() {
        let nomination = inner(
            CTM,
            [
                TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
                Address::repeat_byte(0xBA).into_word().to_vec(),
            ]
            .concat(),
        );
        for calls in [
            vec![replace_call(), nomination.clone()],
            vec![nomination.clone(), replace_call()],
            vec![
                replace_call(),
                deadline_call(DEPARTURE, 1),
                deadline_call(DEPARTURE, 2),
            ],
        ] {
            let err = recover_replacement(&[forward(calls)])
                .unwrap_err()
                .to_string();
            assert!(err.contains("anything else in it is refused"), "{err}");
        }

        // Two targets in one forward.
        let mut elsewhere = deadline_call(DEPARTURE, 1);
        elsewhere.target = Address::repeat_byte(0xC8);
        let err = recover_replacement(&[forward(vec![replace_call(), elsewhere])])
            .unwrap_err()
            .to_string();
        assert!(err.contains("more than one target"), "{err}");

        // Value.
        let mut paying = forward(vec![replace_call()]);
        paying.value = U256::from(1);
        let err = recover_replacement(&[paying]).unwrap_err().to_string();
        assert!(err.contains("carries value"), "{err}");
    }

    #[test]
    fn two_replacing_forwards_are_refused() {
        let err =
            recover_replacement(&[forward(vec![replace_call()]), forward(vec![replace_call()])])
                .unwrap_err()
                .to_string();
        assert!(err.contains("more than one `forward`"), "{err}");
    }

    /// The merged package a replacement prepare produces: no `migrate()`, no executor leg, the
    /// forward in the bundle — classified as its own kind, with every summary field picked up.
    fn replacement_body(replacement: &GovernanceCall, extra_registry: &str) -> String {
        format!(
            "[[external_actions]]\n\
             phase = \"governance\"\n\
             label = \"replace the committed transition departing {DEPARTURE}\"\n\
             authority = \"CTM executor owner (governance)\"\n\
             target = \"{CTM_EXECUTOR}\"\n\
             value = \"0\"\n\
             data = \"0x{}\"\n\
             [governance_calls]\n\
             calls = \"0x{}\"\n\
             [ctms.zksync_os.registry]\n\
             replaced_transition_addr = \"{EXPECTED}\"\n\
             replacement_transition_addr = \"{REPLACEMENT}\"\n\
             ctm_transition_addr = \"{REPLACEMENT}\"\n\
             ctm_infrastructure_transition_addr = \"0x0000000000000000000000000000000000000000\"\n\
             ctm_upgrade_executor_addr = \"{CTM_EXECUTOR}\"\n\
             {extra_registry}\
             [ctms.zksync_os.state_transition]\n\
             chain_type_manager_proxy = \"{CTM}\"\n\
             [ctms.zksync_os.contracts_config]\n\
             old_protocol_version = {DEPARTURE}\n\
             new_protocol_version = {}\n",
            alloy::hex::encode(&replacement.data),
            alloy::hex::encode(crate::common::governance_calls::encode_calls(
                std::slice::from_ref(replacement)
            )),
            DEPARTURE + 0x1_0000_0000,
        )
    }

    #[test]
    fn a_replacement_package_loads_as_its_own_kind() {
        let replacement = forward(vec![replace_call(), deadline_call(DEPARTURE, 7)]);
        let RegistryPackage::Replacement(package) =
            load_str(&replacement_body(&replacement, "")).unwrap()
        else {
            panic!("a forwarded replaceUpgradeTransition must load as a replacement");
        };
        assert_eq!(package.forward.expected, EXPECTED);
        assert_eq!(package.forward.replacement, REPLACEMENT);
        assert_eq!(package.forward.executor, CTM_EXECUTOR);
        assert!(package.forward.deadline.is_some());
        assert_eq!(package.reported_replaced, Some(EXPECTED));
        assert_eq!(package.reported_replacement, Some(REPLACEMENT));
        assert_eq!(package.reported_ctm_executor, Some(CTM_EXECUTOR));
        assert_eq!(package.reported_ctm, Some(CTM));
        assert_eq!(package.reported_old_version, Some(U256::from(DEPARTURE)));
        assert_eq!(package.external_actions.len(), 1);
        assert!(package.external_actions[0].is_call(&replacement));
        assert!(package.executor_records.is_empty());
    }

    /// Q5 mixed kinds: an executor leg beside the replacing `forward`. The replacement's
    /// `ctm_transition_addr` is the replacement, not a transition leg.
    #[test]
    fn upgrade_legs_beside_a_replacement_are_refused() {
        let replacement = forward(vec![replace_call()]);
        let body = replacement_body(&replacement, "").replace(
            &format!(
                "calls = \"0x{}\"",
                alloy::hex::encode(crate::common::governance_calls::encode_calls(
                    std::slice::from_ref(&replacement)
                ))
            ),
            &format!(
                "calls = \"0x{}\"",
                alloy::hex::encode(crate::common::governance_calls::encode_calls(&[
                    replacement.clone(),
                    leg(LegKind::Transition, CTM_EXECUTOR, REPLACEMENT),
                ]))
            ),
        );
        let err = format!("{:#}", load_str(&body).unwrap_err());
        assert!(err.contains("mixed kinds"), "{err}");
        assert!(err.contains("carries no executor leg"), "{err}");
    }

    /// A bootstrap and a replacement in one bundle are two reviews, not one.
    #[test]
    fn a_migrate_beside_a_replacement_is_refused() {
        let replacement = forward(vec![replace_call()]);
        let migrate = call(Address::repeat_byte(0x55), MIGRATE_SELECTOR.to_vec());
        let body = replacement_body(&replacement, "").replace(
            &format!(
                "calls = \"0x{}\"",
                alloy::hex::encode(crate::common::governance_calls::encode_calls(
                    std::slice::from_ref(&replacement)
                ))
            ),
            &format!(
                "calls = \"0x{}\"",
                alloy::hex::encode(crate::common::governance_calls::encode_calls(&[
                    replacement.clone(),
                    migrate,
                ]))
            ),
        );
        let err = format!("{:#}", load_str(&body).unwrap_err());
        assert!(err.contains("mixed kinds"), "{err}");
    }

    /// A replacement whose package also reports a core transition: the merge derives no leg for a
    /// replacement, so the object would never be applied.
    #[test]
    fn a_core_transition_on_a_replacement_is_refused() {
        let replacement = forward(vec![replace_call()]);
        let body = format!(
            "{}[core.registry]\ncore_transition_addr = \"{CORE_TRANSITION}\"\n",
            replacement_body(&replacement, "")
        );
        let err = format!("{:#}", load_str(&body).unwrap_err());
        assert!(err.contains("missing leg"), "{err}");
        assert!(err.contains("core_transition_addr"), "{err}");
    }
}
