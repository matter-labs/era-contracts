//! The reviewable inputs of a v34 bootstrap package.
//!
//! A package is the merged prepare TOML (`ecosystem upgrade-prepare-all`'s output) plus the
//! live L1 it targets.
//!
//! The migration is derived from the stage-1 `migrate()` call rather than read from a field,
//! and stays so deliberately: the verifier should check the calldata governance will actually
//! execute, not the prepare's summary of it. `[registry] bootstrap_migration_addr` is then a
//! cross-check — a disagreement means the summary and the executable calls describe different
//! edges, which is worth a finding of its own.
//!
//! `ctm_transition_addr` and `ctm_upgrade_executor_addr` are both zero for a bootstrap and that
//! is correct, not missing: the edge has no transition, and protocol-ops reads a nonzero
//! executor there as "this prepare's stage calls are executor calls", which a bootstrap's are
//! not. The executor is reported under `bound_ctm_upgrade_executor_addr` instead.

use std::path::Path;

use alloy::primitives::Address;
use anyhow::Context;

use crate::common::governance_calls::{decode_calls, GovernanceCall};

/// `RegistryBootstrapMigration.migrate()`.
pub(crate) const MIGRATE_SELECTOR: [u8; 4] = [0x8f, 0xd3, 0xab, 0x80];
/// `Ownable2Step.transferOwnership(address)`.
pub(crate) const TRANSFER_OWNERSHIP_SELECTOR: [u8; 4] = [0xf2, 0xfd, 0xe3, 0x8b];
/// `RegistryBootstrapMigration.validateApplied()` — the edge asserting its own completion.
pub(crate) const VALIDATE_APPLIED_SELECTOR: [u8; 4] = [0xfe, 0x30, 0xc9, 0xfd];
/// `ChainAssetHandler.pauseMigration()`.
pub(crate) const PAUSE_MIGRATION_SELECTOR: [u8; 4] = [0xac, 0x70, 0x0e, 0x63];
/// `ChainAssetHandler.unpauseMigration()`.
pub(crate) const UNPAUSE_MIGRATION_SELECTOR: [u8; 4] = [0xf7, 0xc7, 0xeb, 0x92];
/// `EcosystemUpgradeExecutor.applyL1Upgrade(ICoreRegistry)` — the ecosystem leg of stage 1.
pub(crate) const APPLY_L1_UPGRADE_SELECTOR: [u8; 4] = [0x60, 0x93, 0xa2, 0x59];

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
    pub(crate) external_actions: Vec<String>,
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

fn calls_at(root: &toml::Value, key: &str) -> anyhow::Result<Vec<GovernanceCall>> {
    let hex = table(root, &["governance_calls", key])
        .and_then(|v| v.as_str())
        .with_context(|| format!("[governance_calls] {key} missing from the package"))?;
    decode_calls(hex).with_context(|| format!("[governance_calls] {key} does not decode as Call[]"))
}

impl BootstrapPackage {
    pub(crate) fn load(ecosystem_toml: &Path) -> anyhow::Result<Self> {
        let raw = std::fs::read_to_string(ecosystem_toml)
            .with_context(|| format!("reading {}", ecosystem_toml.display()))?;
        let root: toml::Value = toml::from_str(&raw)
            .with_context(|| format!("parsing {} as TOML", ecosystem_toml.display()))?;

        // Exactly one CTM section: a bootstrap edge installs the registry model on one CTM.
        let ctms = table(&root, &["ctms"])
            .and_then(|v| v.as_table())
            .context("[ctms] missing from the package — is this a merged prepare output?")?;
        let ctm_key = match ctms.len() {
            1 => ctms.keys().next().expect("len checked").clone(),
            n => anyhow::bail!(
                "expected exactly one [ctms.*] section in a bootstrap package, found {n}: {:?}",
                ctms.keys().collect::<Vec<_>>()
            ),
        };

        let release = address_at(&root, &["ctms", &ctm_key, "registry", "ctm_release_addr"])
            .context("[ctms.*.registry] ctm_release_addr missing or unparseable")?;
        let upgrade_timer =
            address_at(&root, &["ctms", &ctm_key, "registry", "upgrade_timer_addr"])
                .filter(|a| !a.is_zero());
        // The core leg is optional: a CTM-only edge deploys no ecosystem implementations, so
        // the prepare pins no `CoreRegistry` (an all-inert inventory is refused at construction).
        let core_registry =
            address_at(&root, &["core", "registry", "core_registry_addr"]).filter(|a| !a.is_zero());

        let stage0 = calls_at(&root, "stage0_calls")?;
        let stage1 = calls_at(&root, "stage1_calls")?;
        let stage2 = calls_at(&root, "stage2_calls")?;

        let migration = sole_migrate_target(&stage1)?;
        let reported_migration = address_at(
            &root,
            &["ctms", &ctm_key, "registry", "bootstrap_migration_addr"],
        )
        .filter(|a| !a.is_zero());

        let external_actions = table(&root, &["external_actions"])
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();

        Ok(Self {
            core_registry,
            release,
            upgrade_timer,
            migration,
            reported_migration,
            ctm_key,
            stage0,
            stage1,
            stage2,
            external_actions,
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
            "stage 1 contains no `migrate()` call: this is not a v34 bootstrap package \
             (a recurring registry-driven upgrade is verified against its CTMTransition instead)"
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
        for (sig, expected) in [
            (&b"validateApplied()"[..], VALIDATE_APPLIED_SELECTOR),
            (&b"pauseMigration()"[..], PAUSE_MIGRATION_SELECTOR),
            (&b"unpauseMigration()"[..], UNPAUSE_MIGRATION_SELECTOR),
            (&b"applyL1Upgrade(address)"[..], APPLY_L1_UPGRADE_SELECTOR),
        ] {
            assert_eq!(
                &alloy::primitives::keccak256(sig)[..4],
                &expected,
                "selector drifted for {}",
                String::from_utf8_lossy(sig)
            );
        }
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
}
