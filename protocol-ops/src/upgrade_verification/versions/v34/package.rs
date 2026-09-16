//! The reviewable inputs of a v34 package — the merged prepare TOML
//! (`ecosystem upgrade-prepare-all`'s output) plus the live L1 it targets.
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
//!
//! In both kinds an object is recovered from the CALLDATA governance will execute, never from
//! the prepare's summary of it, and the summary field is then a cross-check: a disagreement
//! means the reviewer read one upgrade and governance would sign another.

use std::path::Path;

use alloy::primitives::{Address, B256};
use anyhow::Context;

use crate::common::external_actions::ExternalAction;
use crate::common::governance_calls::{decode_calls, GovernanceCall};

/// `RegistryBootstrapMigration.migrate()`.
pub(crate) const MIGRATE_SELECTOR: [u8; 4] = [0x8f, 0xd3, 0xab, 0x80];
/// `Ownable2Step.transferOwnership(address)`.
pub(crate) const TRANSFER_OWNERSHIP_SELECTOR: [u8; 4] = [0xf2, 0xfd, 0xe3, 0x8b];
/// `RegistryBootstrapMigration.validateApplied()` — the edge asserting its own completion.
pub(crate) const VALIDATE_APPLIED_SELECTOR: [u8; 4] = [0xfe, 0x30, 0xc9, 0xfd];

/// A merged prepare output, classified by the kind of upgrade it drives.
#[derive(Debug)]
pub(crate) enum RegistryPackage {
    /// The ordinary case: one operation, driven through its coordinator.
    Operation(OperationPackage),
    /// The one-time migration onto the registry model.
    Bootstrap(BootstrapPackage),
}

impl RegistryPackage {
    /// Reads `ecosystem_toml` and decides which kind of upgrade it drives.
    ///
    /// `[operation]` is written by the merge itself and only for a package whose CTM prepare
    /// deployed an operation, so its presence is the classification. A package with neither an
    /// operation nor a `migrate()` call is REFUSED rather than verified as the nearest match:
    /// an unrecognised package is an input this tool cannot review.
    pub(crate) fn load(ecosystem_toml: &Path) -> anyhow::Result<Self> {
        let root = read_toml(ecosystem_toml)?;
        if root.get("operation").is_some() {
            return Ok(Self::Operation(OperationPackage::load(
                ecosystem_toml,
                &root,
            )?));
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
    pub(crate) reported_transition: Option<Address>,
    /// `[core.registry] core_registry_addr`, likewise a cross-check on the manifest's.
    pub(crate) reported_core_registry: Option<Address>,
    /// `[ctms.*.registry] ctm_upgrade_executor_addr`, a cross-check on the executor the
    /// coordinator is actually bound to.
    pub(crate) reported_ctm_executor: Option<Address>,
    /// `[ctms.*.registry] upgrade_timer_addr`, a cross-check on the timer the operation pins.
    pub(crate) reported_timer: Option<Address>,
    pub(crate) stage0: Vec<GovernanceCall>,
    pub(crate) stage1: Vec<GovernanceCall>,
    pub(crate) stage2: Vec<GovernanceCall>,
    /// The prepare's declared external actions — calls the operation does NOT describe.
    pub(crate) external_actions: Vec<ExternalAction>,
    /// Every CREATE2 salt the package records; see [`BootstrapPackage::create2_salts`].
    pub(crate) create2_salts: Vec<B256>,
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
            reported_transition: registry_address(root, &ctm_key, "ctm_transition_addr"),
            reported_core_registry: address_at(root, &["core", "registry", "core_registry_addr"])
                .filter(|a| !a.is_zero()),
            reported_ctm_executor: registry_address(root, &ctm_key, "ctm_upgrade_executor_addr"),
            reported_timer: registry_address(root, &ctm_key, "upgrade_timer_addr"),
            stage0: calls_at(root, "stage0_calls")?,
            stage1: calls_at(root, "stage1_calls")?,
            stage2: calls_at(root, "stage2_calls")?,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, &ctm_key),
            ctm_key,
        })
    }
}

#[derive(Debug)]
pub(crate) struct BootstrapPackage {
    /// Objects the prepare names outright.
    pub(crate) core_registry: Option<Address>,
    pub(crate) release: Address,
    /// Absent from protocol-ops-driven prepare output today (the in-forge path emits it),
    /// so it is only ever a cross-check against the manifest's own pin.
    pub(crate) upgrade_timer: Option<Address>,
    /// Recovered from the stage-1 `migrate()` call — the executable source of truth.
    pub(crate) migration: Address,
    /// `[registry] bootstrap_migration_addr`, when the prepare named it: a cross-check on the
    /// address recovered from calldata.
    pub(crate) reported_migration: Option<Address>,
    /// The CTM key under `[ctms]` this package upgrades (e.g. `zksync_os`).
    pub(crate) ctm_key: String,
    pub(crate) stage0: Vec<GovernanceCall>,
    pub(crate) stage1: Vec<GovernanceCall>,
    pub(crate) stage2: Vec<GovernanceCall>,
    /// The prepare's declared external actions — calls the objects do NOT describe.
    pub(crate) external_actions: Vec<ExternalAction>,
    /// Every CREATE2 salt the package records, in the order they were found. A prepare deploys
    /// the core leg under the ecosystem salt and each CTM leg under that CTM's, so an object's
    /// address is re-derivable under one of them — which one is reported rather than assumed.
    /// Empty for a package produced before the prepare recorded them, in which case the reviewer
    /// supplies the reviewed salts on the command line.
    pub(crate) create2_salts: Vec<B256>,
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

fn registry_address(root: &toml::Value, ctm_key: &str, key: &str) -> Option<Address> {
    address_at(root, &["ctms", ctm_key, "registry", key]).filter(|a| !a.is_zero())
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
        // the prepare pins no `CoreRegistry` (an all-inert inventory is refused at construction).
        let core_registry =
            address_at(root, &["core", "registry", "core_registry_addr"]).filter(|a| !a.is_zero());

        Ok(Self {
            core_registry,
            release,
            upgrade_timer,
            migration,
            reported_migration: registry_address(root, &ctm_key, "bootstrap_migration_addr"),
            stage0,
            stage1,
            stage2,
            external_actions: external_actions_in(root)?,
            create2_salts: create2_salts_in(root, &ctm_key),
            ctm_key,
        })
    }
}

/// The migration is whatever stage 1 calls `migrate()` on — and there must be exactly one such
/// call, or the package drives more than one bootstrap edge in a single stage.
fn sole_migrate_target(stage1: &[GovernanceCall]) -> anyhow::Result<Address> {
    let targets: Vec<Address> = stage1
        .iter()
        .filter(|c| c.data.len() == 4 && c.data[..4] == MIGRATE_SELECTOR)
        .map(|c| c.target)
        .collect();
    match targets.as_slice() {
        [one] => Ok(*one),
        [] => anyhow::bail!(
            "stage 1 contains no `migrate()` call, and the package declares no [operation]: it is \
             neither a bootstrap edge nor a recurring registry-driven upgrade, so this tool \
             cannot say what it does"
        ),
        many => anyhow::bail!(
            "stage 1 calls `migrate()` on {} objects ({many:?}); a bootstrap package must drive \
             exactly one edge",
            many.len()
        ),
    }
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
    fn stage_selector_constants_match_their_signatures() {
        assert_eq!(
            &alloy::primitives::keccak256(b"validateApplied()")[..4],
            &VALIDATE_APPLIED_SELECTOR
        );
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
             core_registry_addr = \"0x00000000000000000000000000000000000000ee\"\n\
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
            package.reported_transition,
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
            package.reported_core_registry,
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
}
