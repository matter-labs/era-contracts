//! The reviewable inputs of a registry-driven package — the merged prepare TOML
//! (`ecosystem upgrade-prepare-all`'s output) plus the live L1 it targets.
//!
//! The format carries NO protocol version: which version an upgrade moves chains to lives in the
//! `CTMTransition` the operation pins, and is read from that object on chain. That is why one
//! loader serves every release.
//!
//! Two kinds, told apart by what the prepare deployed rather than by a flag:
//!
//! * a RECURRING operation, the ordinary case. The prepare deployed an
//!   `EcosystemUpgradeOperation` and the merge derived exactly three governance calls from it —
//!   `EcosystemUpgradeExecutor.stage0/1/2(operation)`. Everything executable is a function of
//!   the operation, so the package's reviewable content is that one address.
//! * a BOOTSTRAP edge, the one-time migration onto the registry model. It has no operation and
//!   no coordinator stage calls; governance executes the list a `RegistryBootstrapSequence`
//!   derives.
//! * a transition REPLACEMENT: no operation, no `migrate()`, and one
//!   `CTMUpgradeExecutor.forward` carrying `ChainTypeManager.replaceUpgradeTransition` (see
//!   `protocol-docs/ecosystem-upgrade-coordination.md#replacing-a-committed-transition`).
//!
//! In every kind an object is recovered from the CALLDATA governance will execute, never from
//! the prepare's summary of it, and the summary field is then a cross-check: a disagreement
//! means the reviewer read one upgrade and governance would sign another.

use std::path::Path;

use alloy::primitives::{Address, Bytes, B256, U256};
use anyhow::Context;

use crate::common::external_actions::ExternalAction;
use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::common::governance_calls::{decode_calls, GovernanceCall};

use super::records::records_in;

/// `RegistryBootstrapMigration.migrate()`.
pub(crate) const MIGRATE_SELECTOR: [u8; 4] = [0x8f, 0xd3, 0xab, 0x80];
/// `Ownable2Step.transferOwnership(address)` — the nomination a bundle would smuggle past a
/// reviewer, which the tests append to a derived sequence.
#[cfg(test)]
pub(crate) const TRANSFER_OWNERSHIP_SELECTOR: [u8; 4] = [0xf2, 0xfd, 0xe3, 0x8b];

/// A merged prepare output, classified by the kind of upgrade it drives.
#[derive(Debug)]
pub(crate) enum RegistryPackage {
    /// The ordinary case: one operation, driven through its coordinator.
    Operation(OperationPackage),
    /// The one-time migration onto the registry model.
    Bootstrap(BootstrapPackage),
    /// A compare-and-replace of a committed transition.
    Replacement(Box<ReplacementPackage>),
}

impl RegistryPackage {
    /// Reads `ecosystem_toml` and decides which kind of upgrade it drives.
    ///
    /// `[operation]` is written by the merge itself and only for a package whose CTM prepare
    /// deployed an operation, so its presence is the classification. Otherwise a stage-1
    /// `migrate()` call makes a bootstrap edge, and a `forward` carrying `replaceUpgradeTransition`
    /// a replacement. A package that is none of these is REFUSED rather than verified as the
    /// nearest match: an unrecognised package is an input this tool cannot review.
    pub(crate) fn load(ecosystem_toml: &Path) -> anyhow::Result<Self> {
        let root = read_toml(ecosystem_toml)?;
        if root.get("operation").is_some() {
            return Ok(Self::Operation(OperationPackage::load(
                ecosystem_toml,
                &root,
            )?));
        }
        let stages = [
            calls_at(&root, "stage0_calls")?,
            calls_at(&root, "stage1_calls")?,
            calls_at(&root, "stage2_calls")?,
        ];
        if migrate_targets(&stages[1]).is_empty() {
            if let Some(forward) = recover_replacement(&stages)? {
                return Ok(Self::Replacement(Box::new(ReplacementPackage::load(
                    ecosystem_toml,
                    &root,
                    forward,
                    stages,
                )?)));
            }
        }
        Ok(Self::Bootstrap(BootstrapPackage::load(
            ecosystem_toml,
            &root,
        )?))
    }
}

fn read_toml(ecosystem_toml: &Path) -> anyhow::Result<toml::Value> {
    let raw = std::fs::read_to_string(ecosystem_toml)
        .with_context(|| format!("reading {}", ecosystem_toml.display()))?;
    toml::from_str(&raw).with_context(|| format!("parsing {} as TOML", ecosystem_toml.display()))
}

/// A recurring registry-driven upgrade: one write-once operation and the coordinator that runs
/// its lifecycle.
///
/// The package carries no derived calls of its own to check — the three governance calls ARE
/// `coordinator.stageN(operation)` and nothing else. Everything a reviewer needs beyond those two
/// addresses is read from the operation on chain.
#[derive(Debug)]
pub(crate) struct OperationPackage {
    /// `[operation] operation_addr` — the object the three stage calls name.
    pub(crate) operation: Address,
    /// `[operation] coordinator_addr` — the `EcosystemUpgradeExecutor` they are sent to.
    pub(crate) coordinator: Address,
    /// The CTM key under `[ctms]` this package upgrades (e.g. `zksync_os`).
    pub(crate) ctm_key: String,
    /// `[ctms.*.registry] ctm_transition_addr`, when the prepare named one: a cross-check on the
    /// transition the operation's own manifest pins.
    pub(crate) reported_ctm_transition: Option<Address>,
    /// `[core.registry] core_transition_addr`, likewise a cross-check on the manifest's.
    pub(crate) reported_core_transition: Option<Address>,
    /// `[ctms.*.registry] ctm_upgrade_executor_addr`, a cross-check on the executor the
    /// coordinator is actually bound to.
    pub(crate) reported_ctm_executor: Option<Address>,
    /// `[ctms.*.registry] upgrade_timer_addr`, a cross-check on the timer the operation pins.
    pub(crate) reported_timer: Option<Address>,
    /// `[ctms.*.state_transition] chain_type_manager_proxy` — the CTM this package upgrades.
    ///
    /// An operation names no CTM (the binding is the CTM executor's immutable), so this is the
    /// only value in the package the executor's `CHAIN_TYPE_MANAGER` can be held against. Without
    /// it, that binding is derived and unverified, which the verifier reports as an error rather
    /// than comparing the read value with itself.
    pub(crate) reported_ctm: Option<Address>,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin` — likewise for the executor's
    /// `CTM_PROXY_ADMIN`.
    pub(crate) reported_ctm_proxy_admin: Option<Address>,
    pub(crate) stage0: Vec<GovernanceCall>,
    pub(crate) stage1: Vec<GovernanceCall>,
    pub(crate) stage2: Vec<GovernanceCall>,
    /// The prepare's declared external actions — calls the operation does NOT describe.
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
}

impl OperationPackage {
    fn load(ecosystem_toml: &Path, root: &toml::Value) -> anyhow::Result<Self> {
        let operation = address_at(root, &["operation", "operation_addr"])
            .filter(|a| !a.is_zero())
            .with_context(|| {
                format!(
                    "[operation] operation_addr missing, zero or unparsable in {}",
                    ecosystem_toml.display()
                )
            })?;
        let coordinator = address_at(root, &["operation", "coordinator_addr"])
            .filter(|a| !a.is_zero())
            .with_context(|| {
                format!(
                    "[operation] coordinator_addr missing, zero or unparsable in {}: the \
                     operation names no place to be driven from",
                    ecosystem_toml.display()
                )
            })?;
        let ctm_key = sole_ctm_key(root)?;

        Ok(Self {
            operation,
            coordinator,
            reported_ctm_transition: registry_address(root, &ctm_key, "ctm_transition_addr"),
            reported_core_transition: address_at(
                root,
                &["core", "registry", "core_transition_addr"],
            )
            .filter(|a| !a.is_zero()),
            reported_ctm_executor: registry_address(root, &ctm_key, "ctm_upgrade_executor_addr"),
            reported_timer: registry_address(root, &ctm_key, "upgrade_timer_addr"),
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
            stage0: calls_at(root, "stage0_calls")?,
            stage1: calls_at(root, "stage1_calls")?,
            stage2: calls_at(root, "stage2_calls")?,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, &ctm_key),
            lifecycle: lifecycle_inputs_in(root, &ctm_key),
            force_deployments_data: force_deployments_data_in(root, &ctm_key),
            executor_records: records_in(root, &ecosystem_toml.display().to_string())?,
            ctm_key,
        })
    }
}

/// The package's record of the values the lifecycle objects — the coordinator, the two domain
/// executors and the timer — were constructed over. Those objects set their bindings as
/// constructor immutables, so their construction is the only identity check they get, and it is
/// held to THESE values (plus the bootstrap manifest) rather than to the objects' own answers: the
/// timer is re-derived from them, and the executors' recorded bindings are held against them.
///
/// Each is optional at load so the report can name exactly which one an older package lacks;
/// the construction check ERRORS on a missing one rather than skipping the object.
#[derive(Debug, Default)]
pub(crate) struct LifecycleInputs {
    /// `[core.registry] core_upgrade_executor_addr` — the core executor the coordinator was
    /// built over.
    pub(crate) core_executor: Option<Address>,
    /// `[core.upgrade_addresses.shared] transparent_proxy_admin` — the ecosystem `ProxyAdmin`
    /// the core executor was built over.
    pub(crate) core_proxy_admin: Option<Address>,
    /// `[ctms.*.contracts_config] governance_upgrade_timer_initial_delay` — the timer's
    /// `INITIAL_DELAY`.
    pub(crate) timer_initial_delay: Option<U256>,
    /// `[ctms.*.admin] timer_governance_addr` — the prepare's statement of who starts the timer,
    /// a cross-check on the reviewed value the construction uses.
    pub(crate) timer_governance: Option<Address>,
    /// `[ctms.*.admin] ecosystem_admin_addr` — the timer's initial owner (who may extend its
    /// deadline).
    pub(crate) timer_owner: Option<Address>,
}

fn lifecycle_inputs_in(root: &toml::Value, ctm_key: &str) -> LifecycleInputs {
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
        timer_initial_delay: u256_at(
            root,
            &[
                "ctms",
                ctm_key,
                "contracts_config",
                "governance_upgrade_timer_initial_delay",
            ],
        ),
        timer_governance: ctm_address(root, ctm_key, "admin", "timer_governance_addr"),
        timer_owner: ctm_address(root, ctm_key, "admin", "ecosystem_admin_addr"),
    }
}

#[derive(Debug)]
pub(crate) struct BootstrapPackage {
    /// Objects the prepare names outright.
    pub(crate) core_transition: Option<Address>,
    pub(crate) release: Address,
    /// Absent from protocol-ops-driven prepare output today (the in-forge path emits it),
    /// so it is only ever a cross-check against the manifest's own pin.
    pub(crate) upgrade_timer: Option<Address>,
    /// Recovered from the stage-1 `migrate()` call — the executable source of truth.
    pub(crate) migration: Address,
    /// `[registry] bootstrap_migration_addr`, when the prepare named it: a cross-check on the
    /// address recovered from calldata.
    pub(crate) reported_migration: Option<Address>,
    /// `[ctms.*.registry] coordinator_addr`, a cross-check on the manifest's coordinator.
    pub(crate) reported_coordinator: Option<Address>,
    /// `[ctms.*.registry] ctm_upgrade_executor_addr`, a cross-check on the manifest's executor.
    pub(crate) reported_ctm_executor: Option<Address>,
    /// `[ctms.*.state_transition] chain_type_manager_proxy`, a cross-check on the manifest's CTM.
    pub(crate) reported_ctm: Option<Address>,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin`, a cross-check on the manifest's
    /// CTM-domain ProxyAdmin.
    pub(crate) reported_ctm_proxy_admin: Option<Address>,
    /// The CTM key under `[ctms]` this package upgrades (e.g. `zksync_os`).
    pub(crate) ctm_key: String,
    pub(crate) stage0: Vec<GovernanceCall>,
    pub(crate) stage1: Vec<GovernanceCall>,
    pub(crate) stage2: Vec<GovernanceCall>,
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
fn create2_salts_in(root: &toml::Value, ctm_key: &str) -> Vec<B256> {
    let candidates = [
        vec!["misc", "create2_factory_salt"],
        vec!["core", "create2_factory_salt"],
        vec!["ctms", ctm_key, "create2_factory_salt"],
    ];
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

fn calls_at(root: &toml::Value, key: &str) -> anyhow::Result<Vec<GovernanceCall>> {
    let hex = table(root, &["governance_calls", key])
        .and_then(|v| v.as_str())
        .with_context(|| format!("[governance_calls] {key} missing from the package"))?;
    decode_calls(hex).with_context(|| format!("[governance_calls] {key} does not decode as Call[]"))
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
/// Both kinds of package are single-CTM by construction — the prepare boundary admits one
/// ZKsync OS CTM, and one operation names one transition — so more than one section means the
/// verifier would be reading one upgrade's objects while reporting on another's.
fn sole_ctm_key(root: &toml::Value) -> anyhow::Result<String> {
    let ctms = table(root, &["ctms"])
        .and_then(|v| v.as_table())
        .context("[ctms] missing from the package — is this a merged prepare output?")?;
    match ctms.len() {
        1 => Ok(ctms.keys().next().expect("len checked").clone()),
        n => anyhow::bail!(
            "expected exactly one [ctms.*] section, found {n}: {:?}",
            ctms.keys().collect::<Vec<_>>()
        ),
    }
}

impl BootstrapPackage {
    fn load(ecosystem_toml: &Path, root: &toml::Value) -> anyhow::Result<Self> {
        let stage0 = calls_at(root, "stage0_calls")?;
        let stage1 = calls_at(root, "stage1_calls")?;
        let stage2 = calls_at(root, "stage2_calls")?;

        // The classification failure comes FIRST: a package that is neither kind must say so,
        // rather than report the first bootstrap-shaped field it happens to be missing.
        let migration = sole_migrate_target(&stage1).with_context(|| {
            format!(
                "{} carries no [operation] section, so it was read as a bootstrap package",
                ecosystem_toml.display()
            )
        })?;

        let ctm_key = sole_ctm_key(root)?;
        let release = registry_address(root, &ctm_key, "ctm_release_addr")
            .context("[ctms.*.registry] ctm_release_addr missing, zero or unparsable")?;
        let upgrade_timer = registry_address(root, &ctm_key, "upgrade_timer_addr");
        // The core leg is optional: a CTM-only edge deploys no ecosystem implementations, so
        // the prepare pins no `CoreTransition` (an all-inert inventory is refused at construction).
        let core_transition = address_at(root, &["core", "registry", "core_transition_addr"])
            .filter(|a| !a.is_zero());

        Ok(Self {
            core_transition,
            release,
            upgrade_timer,
            migration,
            reported_migration: registry_address(root, &ctm_key, "bootstrap_migration_addr"),
            reported_coordinator: registry_address(root, &ctm_key, "coordinator_addr"),
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
            stage0,
            stage1,
            stage2,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, &ctm_key),
            lifecycle: lifecycle_inputs_in(root, &ctm_key),
            force_deployments_data: force_deployments_data_in(root, &ctm_key),
            executor_records: records_in(root, &ecosystem_toml.display().to_string())?,
            ctm_key,
        })
    }
}

/// Every target stage 1 calls `migrate()` on — the bootstrap migrations a bundle drives.
pub(crate) fn migrate_targets(stage1: &[GovernanceCall]) -> Vec<Address> {
    stage1
        .iter()
        .filter(|c| c.data.len() == 4 && c.data[..4] == MIGRATE_SELECTOR)
        .map(|c| c.target)
        .collect()
}

/// The migration is whatever stage 1 calls `migrate()` on — and there must be exactly one such
/// call, or the package drives more than one bootstrap edge in a single stage.
fn sole_migrate_target(stage1: &[GovernanceCall]) -> anyhow::Result<Address> {
    match migrate_targets(stage1).as_slice() {
        [one] => Ok(*one),
        [] => anyhow::bail!(
            "stage 1 contains no `migrate()` call, the package declares no [operation] and no \
             `forward` replaces a transition: it is neither a bootstrap edge, a recurring \
             registry-driven upgrade nor a transition replacement, so this tool cannot say what \
             it does"
        ),
        many => anyhow::bail!(
            "stage 1 calls `migrate()` on {} objects ({many:?}); a bootstrap package must drive \
             exactly one edge",
            many.len()
        ),
    }
}

/// A replacement of a committed transition: one `CTMUpgradeExecutor.forward` carrying
/// `ChainTypeManager.replaceUpgradeTransition(expected, replacement)`, optionally followed by
/// `setProtocolVersionDeadline`. Its prepare deploys the replacement alone — no release (it lands
/// on an existing one), no operation, no timer, no executor.
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
    /// `[ctms.*.registry] coordinator_addr` — the coordinator the CTM executor answers to.
    pub(crate) reported_coordinator: Option<Address>,
    /// `[ctms.*.state_transition] chain_type_manager_proxy`, a cross-check on the inner target and
    /// the value the CTM executor's `CHAIN_TYPE_MANAGER` is held against.
    pub(crate) reported_ctm: Option<Address>,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin` — the CTM executor's
    /// `CTM_PROXY_ADMIN` is held against it.
    pub(crate) reported_ctm_proxy_admin: Option<Address>,
    /// `[core.registry] core_transition_addr` — a core leg a replacement does not carry.
    pub(crate) reported_core_transition: Option<Address>,
    pub(crate) stage0: Vec<GovernanceCall>,
    pub(crate) stage1: Vec<GovernanceCall>,
    pub(crate) stage2: Vec<GovernanceCall>,
    /// The prepare's declared external actions (the forward is one of them).
    pub(crate) external_actions: Vec<ExternalAction>,
    /// Every CREATE2 salt the package records; see [`BootstrapPackage::create2_salts`].
    pub(crate) create2_salts: Vec<B256>,
    /// The package's record of the lifecycle objects' binding values.
    pub(crate) lifecycle: LifecycleInputs,
    /// `[ctms.*.contracts_config] old_protocol_version` — the replaced transition's departing
    /// version, a cross-check.
    pub(crate) reported_old_version: Option<U256>,
    /// `[ctms.*.contracts_config] new_protocol_version` — the replacement's target, a cross-check.
    pub(crate) reported_new_version: Option<U256>,
    /// The executor records the reviewer added with `--executor-record` (the prepare deploys no
    /// executor, so the package itself normally carries none).
    pub(crate) executor_records: UpgradeExecutorsRecord,
}

impl ReplacementPackage {
    fn load(
        ecosystem_toml: &Path,
        root: &toml::Value,
        forward: RecoveredReplacement,
        [stage0, stage1, stage2]: [Vec<GovernanceCall>; 3],
    ) -> anyhow::Result<Self> {
        let ctm_key = sole_ctm_key(root)?;
        Ok(Self {
            forward,
            reported_replaced: registry_address(root, &ctm_key, "replaced_transition_addr"),
            reported_replacement: registry_address(root, &ctm_key, "replacement_transition_addr"),
            reported_ctm_transition: registry_address(root, &ctm_key, "ctm_transition_addr"),
            reported_release: registry_address(root, &ctm_key, "ctm_release_addr"),
            reported_ctm_executor: registry_address(root, &ctm_key, "ctm_upgrade_executor_addr"),
            reported_coordinator: registry_address(root, &ctm_key, "coordinator_addr"),
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
            reported_core_transition: address_at(
                root,
                &["core", "registry", "core_transition_addr"],
            )
            .filter(|a| !a.is_zero()),
            stage0,
            stage1,
            stage2,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, &ctm_key),
            lifecycle: lifecycle_inputs_in(root, &ctm_key),
            reported_old_version: u256_at(
                root,
                &["ctms", &ctm_key, "contracts_config", "old_protocol_version"],
            ),
            reported_new_version: u256_at(
                root,
                &["ctms", &ctm_key, "contracts_config", "new_protocol_version"],
            ),
            executor_records: records_in(root, &ecosystem_toml.display().to_string())?,
            ctm_key,
        })
    }
}

/// The replacement as the calldata states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RecoveredReplacement {
    /// The stage the forward sits in (`0..=2`) and its index there.
    pub(crate) stage: usize,
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

/// The `forward` that replaces a transition, if any call of any stage is one.
///
/// A forward counts when one of its inner calls has `replaceUpgradeTransition`'s selector; it must
/// then be exactly `[replaceUpgradeTransition]` or `[replaceUpgradeTransition,
/// setProtocolVersionDeadline]` on one target, carrying no value — anything else in it is
/// refused, since this tool would otherwise verify the replacement and wave the rest through.
pub(crate) fn recover_replacement(
    stages: &[Vec<GovernanceCall>; 3],
) -> anyhow::Result<Option<RecoveredReplacement>> {
    use super::views::{CTMUpgradeExecutorView, CtmView};
    use alloy::sol_types::SolCall;

    let replace_selector = CtmView::replaceUpgradeTransitionCall::SELECTOR;
    let mut found: Option<RecoveredReplacement> = None;
    for (stage, calls) in stages.iter().enumerate() {
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
                "more than one `forward` replaces a transition (stage {stage}, call {index}, and \
                 an earlier one): a replacement package replaces exactly one"
            );
            anyhow::ensure!(
                call.value.is_zero() && inner.iter().all(|c| c.value.is_zero()),
                "the `forward` that replaces a transition (stage {stage}, call {index}) carries \
                 value; a replacement moves none"
            );
            let shape = |why: &str| {
                anyhow::anyhow!(
                    "the `forward` that replaces a transition (stage {stage}, call {index}) {why}: \
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
                    let call = CtmView::setProtocolVersionDeadlineCall::abi_decode(&c.data)
                        .map_err(|_| {
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
                stage,
                index,
                executor: call.target,
                ctm,
                expected: replace._expectedTransition,
                replacement: replace._replacement,
                deadline,
            });
        }
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

    #[test]
    fn recovers_the_migration_from_stage_one() {
        let migration = Address::repeat_byte(0xAB);
        let stage1 = vec![
            call(
                Address::repeat_byte(0x11),
                TRANSFER_OWNERSHIP_SELECTOR.to_vec(),
            ),
            call(migration, MIGRATE_SELECTOR.to_vec()),
        ];
        assert_eq!(sole_migrate_target(&stage1).unwrap(), migration);
    }

    #[test]
    fn rejects_a_package_with_no_migrate_call() {
        let stage1 = vec![call(
            Address::repeat_byte(0x11),
            vec![0xde, 0xad, 0xbe, 0xef],
        )];
        let err = sole_migrate_target(&stage1).unwrap_err().to_string();
        assert!(err.contains("no `migrate()` call"), "{err}");
    }

    #[test]
    fn rejects_a_package_driving_two_edges() {
        let stage1 = vec![
            call(Address::repeat_byte(0xAA), MIGRATE_SELECTOR.to_vec()),
            call(Address::repeat_byte(0xBB), MIGRATE_SELECTOR.to_vec()),
        ];
        let err = sole_migrate_target(&stage1).unwrap_err().to_string();
        assert!(err.contains("exactly one edge"), "{err}");
    }

    const OPERATION: &str = "0x00000000000000000000000000000000000000aa";
    const COORDINATOR: &str = "0x00000000000000000000000000000000000000bb";

    /// A merged prepare output for a recurring upgrade, trimmed to the fields the loader reads.
    fn recurring_toml(operation_section: &str) -> String {
        format!(
            "{operation_section}\n\
             [ctms.zksync_os.registry]\n\
             ctm_transition_addr = \"0x00000000000000000000000000000000000000cc\"\n\
             ctm_upgrade_executor_addr = \"0x00000000000000000000000000000000000000dd\"\n\
             [core.registry]\n\
             core_transition_addr = \"0x00000000000000000000000000000000000000ee\"\n\
             [governance_calls]\n\
             stage0_calls = \"0x\"\n\
             stage1_calls = \"0x\"\n\
             stage2_calls = \"0x\"\n"
        )
    }

    fn load_str(body: &str) -> anyhow::Result<RegistryPackage> {
        let dir = std::env::temp_dir().join(format!(
            "protocol-ops-package-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ecosystem.toml");
        std::fs::write(&path, body).unwrap();
        RegistryPackage::load(&path)
    }

    /// The classification: `[operation]` is written only for a package whose prepare deployed
    /// one, so its presence — not a flag, and not a guess from the calldata — decides which
    /// verifier runs.
    #[test]
    fn an_operation_section_classifies_the_package_as_recurring() {
        let body = recurring_toml(&format!(
            "[operation]\noperation_addr = \"{OPERATION}\"\ncoordinator_addr = \"{COORDINATOR}\"\n"
        ));
        let RegistryPackage::Operation(package) = load_str(&body).unwrap() else {
            panic!("a package naming an operation must be read as a recurring upgrade");
        };
        assert_eq!(package.operation, OPERATION.parse::<Address>().unwrap());
        assert_eq!(package.coordinator, COORDINATOR.parse::<Address>().unwrap());
        assert_eq!(package.ctm_key, "zksync_os");
        assert_eq!(
            package.reported_ctm_transition,
            Some(
                "0x00000000000000000000000000000000000000cc"
                    .parse()
                    .unwrap()
            )
        );
        assert_eq!(
            package.reported_ctm_executor,
            Some(
                "0x00000000000000000000000000000000000000dd"
                    .parse()
                    .unwrap()
            )
        );
        assert_eq!(
            package.reported_core_transition,
            Some(
                "0x00000000000000000000000000000000000000ee"
                    .parse()
                    .unwrap()
            )
        );
    }

    /// An operation with nothing to drive it is refused at load rather than verified with the
    /// coordinator left unknown: the three stage calls have no target without it.
    #[test]
    fn an_operation_without_a_coordinator_is_refused() {
        let body = recurring_toml(&format!("[operation]\noperation_addr = \"{OPERATION}\"\n"));
        let err = load_str(&body).unwrap_err().to_string();
        assert!(err.contains("coordinator_addr"), "{err}");
    }

    /// A package that is neither kind must not be verified as the nearest match.
    #[test]
    fn a_package_that_is_neither_kind_is_refused() {
        let body = recurring_toml("");
        let err = format!("{:#}", load_str(&body).unwrap_err());
        assert!(err.contains("no `migrate()` call"), "{err}");
    }

    // ───────────────────────── a release the tool has never heard of ─────────────────────────
    //
    // `CTMUpgrade_v36 is DefaultCTMUpgrade {}` — an empty subclass. A v36 upgrade is an ORDINARY
    // registry operation, so it must verify through the general path with no v36 module, no v36
    // branch and no v36 constant anywhere in this tree. These pin that: the loader never learns
    // a release name, so the same code serves v36 and everything after it.

    /// The merged prepare output of a v36-shaped release, in the exact shape
    /// `write_merged_ecosystem_toml` emits for a CTM prepare that deployed an operation: the
    /// derived `[operation]` section, the CTM's summary fields, and a ZERO
    /// `bootstrap_migration_addr` — the field a bootstrap fills and every later release does not.
    fn ordinary_release_toml() -> String {
        format!(
            "[operation]\n\
             operation_addr = \"{OPERATION}\"\n\
             coordinator_addr = \"{COORDINATOR}\"\n\
             [ctms.zksync_os.registry]\n\
             ctm_transition_addr = \"0x00000000000000000000000000000000000000cc\"\n\
             ctm_release_addr = \"0x00000000000000000000000000000000000000c1\"\n\
             upgrade_timer_addr = \"0x00000000000000000000000000000000000000c2\"\n\
             bootstrap_migration_addr = \"0x0000000000000000000000000000000000000000\"\n\
             ctm_upgrade_executor_addr = \"0x00000000000000000000000000000000000000dd\"\n\
             coordinator_addr = \"{COORDINATOR}\"\n\
             operation_addr = \"{OPERATION}\"\n\
             [ctms.zksync_os.state_transition]\n\
             chain_type_manager_proxy = \"0x00000000000000000000000000000000000000f1\"\n\
             [ctms.zksync_os.deployed_addresses]\n\
             transparent_proxy_admin = \"0x00000000000000000000000000000000000000f2\"\n\
             [ctms.zksync_os.admin]\n\
             timer_governance_addr = \"{COORDINATOR}\"\n\
             ecosystem_admin_addr = \"0x00000000000000000000000000000000000000f3\"\n\
             [ctms.zksync_os.contracts_config]\n\
             governance_upgrade_timer_initial_delay = 172800\n\
             force_deployments_data = \"0xf0f1f2\"\n\
             [core.registry]\n\
             core_transition_addr = \"0x00000000000000000000000000000000000000ee\"\n\
             core_upgrade_executor_addr = \"0x00000000000000000000000000000000000000e1\"\n\
             ecosystem_upgrade_executor_addr = \"{COORDINATOR}\"\n\
             [core.upgrade_addresses.shared]\n\
             transparent_proxy_admin = \"0x00000000000000000000000000000000000000e2\"\n\
             [governance_calls]\n\
             stage0_calls = \"0x\"\n\
             stage1_calls = \"0x\"\n\
             stage2_calls = \"0x\"\n"
        )
    }

    /// A release with no module of its own loads as an ordinary operation, and every summary
    /// field the verifier cross-checks is picked up — including the two that hold the CTM
    /// executor's immutables to something the review fixes.
    #[test]
    fn a_release_with_no_module_of_its_own_loads_as_an_ordinary_operation() {
        let RegistryPackage::Operation(package) = load_str(&ordinary_release_toml()).unwrap()
        else {
            panic!("an ordinary release must not need a verifier module of its own");
        };
        assert_eq!(package.operation, OPERATION.parse::<Address>().unwrap());
        assert_eq!(package.coordinator, COORDINATOR.parse::<Address>().unwrap());
        assert_eq!(
            package.reported_timer,
            Some(
                "0x00000000000000000000000000000000000000c2"
                    .parse()
                    .unwrap()
            )
        );
        assert_eq!(
            package.reported_ctm,
            Some(
                "0x00000000000000000000000000000000000000f1"
                    .parse()
                    .unwrap()
            )
        );
        assert_eq!(
            package.reported_ctm_proxy_admin,
            Some(
                "0x00000000000000000000000000000000000000f2"
                    .parse()
                    .unwrap()
            )
        );
    }

    /// The lifecycle objects' binding values are read from where the two prepares write them —
    /// the core output's registry and shared-admin sections, the CTM output's admin and config
    /// sections — because the timer's construction is re-derived from them and the executors'
    /// recorded bindings are held against them.
    #[test]
    fn the_lifecycle_inputs_are_read_from_both_prepare_outputs() {
        let RegistryPackage::Operation(package) = load_str(&ordinary_release_toml()).unwrap()
        else {
            panic!("an ordinary release");
        };
        let lifecycle = &package.lifecycle;
        assert_eq!(
            lifecycle.core_executor,
            Some(
                "0x00000000000000000000000000000000000000e1"
                    .parse()
                    .unwrap()
            )
        );
        assert_eq!(
            lifecycle.core_proxy_admin,
            Some(
                "0x00000000000000000000000000000000000000e2"
                    .parse()
                    .unwrap()
            )
        );
        assert_eq!(lifecycle.timer_initial_delay, Some(U256::from(172_800u64)));
        assert_eq!(
            lifecycle.timer_governance,
            Some(COORDINATOR.parse::<Address>().unwrap())
        );
        assert_eq!(
            lifecycle.timer_owner,
            Some(
                "0x00000000000000000000000000000000000000f3"
                    .parse()
                    .unwrap()
            )
        );
    }

    /// The force-deployments blob the release genesis is held against comes from the CTM
    /// prepare's output; a package without it loads with it absent, and the release check then
    /// reports it.
    #[test]
    fn the_force_deployments_data_is_read_from_the_ctm_prepare_output() {
        let RegistryPackage::Operation(package) = load_str(&ordinary_release_toml()).unwrap()
        else {
            panic!("an ordinary release");
        };
        assert_eq!(
            package.force_deployments_data,
            Some(Bytes::from_static(&[0xf0, 0xf1, 0xf2]))
        );

        let body = recurring_toml(&format!(
            "[operation]\noperation_addr = \"{OPERATION}\"\ncoordinator_addr = \"{COORDINATOR}\"\n"
        ));
        let RegistryPackage::Operation(package) = load_str(&body).unwrap() else {
            panic!("an ordinary release");
        };
        assert!(package.force_deployments_data.is_none());
    }

    /// A package produced before the prepare recorded the lifecycle values loads with them
    /// absent — the verifier then reports each construction it cannot run, rather than the
    /// loader refusing a package it can otherwise review.
    #[test]
    fn a_package_without_lifecycle_inputs_loads_with_them_absent() {
        let body = recurring_toml(&format!(
            "[operation]\noperation_addr = \"{OPERATION}\"\ncoordinator_addr = \"{COORDINATOR}\"\n"
        ));
        let RegistryPackage::Operation(package) = load_str(&body).unwrap() else {
            panic!("an ordinary release");
        };
        assert!(package.lifecycle.core_executor.is_none());
        assert!(package.lifecycle.core_proxy_admin.is_none());
        assert!(package.lifecycle.timer_initial_delay.is_none());
        assert!(package.lifecycle.timer_owner.is_none());
    }

    // ───────────────────────── transition replacements ─────────────────────────

    use super::super::views::{BootstrapCall, CTMUpgradeExecutorView, CtmView};
    use alloy::sol_types::SolCall;

    const CTM: Address = Address::repeat_byte(0xC7);
    const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);
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

    fn stages(stage1: Vec<GovernanceCall>) -> [Vec<GovernanceCall>; 3] {
        [Vec::new(), stage1, Vec::new()]
    }

    #[test]
    fn recovers_a_replacement_from_its_forward() {
        let recovered = recover_replacement(&stages(vec![forward(vec![replace_call()])]))
            .unwrap()
            .expect("a forward of replaceUpgradeTransition is a replacement");
        assert_eq!(
            recovered,
            RecoveredReplacement {
                stage: 1,
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
        let recovered = recover_replacement(&stages(vec![
            call(Address::repeat_byte(0x11), vec![0xde, 0xad, 0xbe, 0xef]),
            forward(vec![
                replace_call(),
                deadline_call(DEPARTURE, 1_900_000_000),
            ]),
        ]))
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
        assert!(recover_replacement(&stages(vec![forward(vec![accept])]))
            .unwrap()
            .is_none());
        assert!(recover_replacement(&stages(Vec::new())).unwrap().is_none());
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
            let err = recover_replacement(&stages(vec![forward(calls)]))
                .unwrap_err()
                .to_string();
            assert!(err.contains("anything else in it is refused"), "{err}");
        }

        // Two targets in one forward.
        let mut elsewhere = deadline_call(DEPARTURE, 1);
        elsewhere.target = Address::repeat_byte(0xC8);
        let err = recover_replacement(&stages(vec![forward(vec![replace_call(), elsewhere])]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("more than one target"), "{err}");

        // Value.
        let mut paying = forward(vec![replace_call()]);
        paying.value = U256::from(1);
        let err = recover_replacement(&stages(vec![paying]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("carries value"), "{err}");
    }

    #[test]
    fn two_replacing_forwards_are_refused() {
        let err = recover_replacement(&[
            vec![forward(vec![replace_call()])],
            vec![forward(vec![replace_call()])],
            Vec::new(),
        ])
        .unwrap_err()
        .to_string();
        assert!(err.contains("more than one `forward`"), "{err}");
    }

    /// The merged package a replacement prepare produces: no [operation], no `migrate()`, the
    /// forward in stage 1 — classified as its own kind, with every summary field picked up.
    #[test]
    fn a_replacement_package_loads_as_its_own_kind() {
        let stage1 = forward(vec![replace_call(), deadline_call(DEPARTURE, 7)]);
        let body = format!(
            "[[external_actions]]\n\
             phase = \"1\"\n\
             label = \"replace the committed transition departing {DEPARTURE}\"\n\
             authority = \"CTM executor owner (governance)\"\n\
             target = \"{CTM_EXECUTOR}\"\n\
             value = \"0\"\n\
             data = \"0x{}\"\n\
             [governance_calls]\n\
             stage0_calls = \"0x\"\n\
             stage1_calls = \"0x{}\"\n\
             stage2_calls = \"0x\"\n\
             [ctms.zksync_os.registry]\n\
             replaced_transition_addr = \"{EXPECTED}\"\n\
             replacement_transition_addr = \"{REPLACEMENT}\"\n\
             ctm_transition_addr = \"{REPLACEMENT}\"\n\
             ctm_upgrade_executor_addr = \"{CTM_EXECUTOR}\"\n\
             coordinator_addr = \"{COORDINATOR}\"\n\
             operation_addr = \"0x0000000000000000000000000000000000000000\"\n\
             upgrade_timer_addr = \"0x0000000000000000000000000000000000000000\"\n\
             [ctms.zksync_os.state_transition]\n\
             chain_type_manager_proxy = \"{CTM}\"\n\
             [ctms.zksync_os.contracts_config]\n\
             old_protocol_version = {DEPARTURE}\n\
             new_protocol_version = {}\n",
            alloy::hex::encode(&stage1.data),
            alloy::hex::encode(crate::common::governance_calls::encode_calls(
                std::slice::from_ref(&stage1)
            )),
            DEPARTURE + 0x1_0000_0000,
        );
        let RegistryPackage::Replacement(package) = load_str(&body).unwrap() else {
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
        assert_eq!(
            package.reported_coordinator,
            Some(COORDINATOR.parse::<Address>().unwrap())
        );
        assert_eq!(package.reported_old_version, Some(U256::from(DEPARTURE)));
        assert_eq!(package.external_actions.len(), 1);
        assert!(package.external_actions[0].is_call(&stage1));
        assert!(package.executor_records.is_empty());
    }

    /// The zero `bootstrap_migration_addr` a post-bootstrap release carries must not divert it
    /// into the bootstrap path — where it would be refused for having no `migrate()` call.
    #[test]
    fn a_zero_bootstrap_field_does_not_divert_an_ordinary_release() {
        let body = ordinary_release_toml();
        assert!(body.contains("bootstrap_migration_addr"));
        assert!(matches!(
            load_str(&body).unwrap(),
            RegistryPackage::Operation(_)
        ));
    }
}
