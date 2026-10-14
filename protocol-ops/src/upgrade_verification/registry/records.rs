//! The executor records a review re-derives the executors' construction from.
//!
//! An executor's address commits to its ORIGINAL constructor arguments — the owner it was built
//! for and, for the CTM executor, the coordinator it was built with — and both may move afterwards
//! (`transferOwnership`, `setCoordinator`). Re-deriving from the current values therefore cannot
//! tell a genuine executor whose owner moved from a counterfeit; re-deriving from what the
//! deploying run RECORDED can ([`super::lifecycle`]).
//!
//! A record sits wherever a run that deployed executors wrote its `[upgrade_executors]` table:
//! at the root of a forge init output (`DeployL1CoreContracts`, `DeployCTM`), and under `[core]` /
//! `[ctms.<key>]` of a merged prepare package (`CoreUpgrade_v35`, `CTMUpgrade_v35`). Records from
//! several files merge into one set; two DIFFERENT records of the same executor are refused, since
//! the review cannot say which one describes the object it verifies.

use std::path::Path;

use anyhow::Context;

use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;

/// Every `[upgrade_executors]` table in `root` — at the root, under `[core]` and under each
/// `[ctms.<key>]` — merged into one set. `source` names the file in errors.
pub(crate) fn records_in(
    root: &toml::Value,
    source: &str,
) -> anyhow::Result<UpgradeExecutorsRecord> {
    let mut locations: Vec<(String, &toml::Value)> = Vec::new();
    if let Some(value) = root.get("upgrade_executors") {
        locations.push(("[upgrade_executors]".to_string(), value));
    }
    if let Some(value) = root
        .get("core")
        .and_then(|core| core.get("upgrade_executors"))
    {
        locations.push(("[core.upgrade_executors]".to_string(), value));
    }
    if let Some(ctms) = root.get("ctms").and_then(toml::Value::as_table) {
        for (key, ctm) in ctms {
            if let Some(value) = ctm.get("upgrade_executors") {
                locations.push((format!("[ctms.{key}.upgrade_executors]"), value));
            }
        }
    }

    let mut merged = UpgradeExecutorsRecord::default();
    for (location, value) in locations {
        let record: UpgradeExecutorsRecord = value.clone().try_into().with_context(|| {
            format!("{source}: {location} does not decode as an executor record")
        })?;
        merge_records(&mut merged, record, &format!("{source} {location}"))?;
    }
    Ok(merged)
}

/// The records of a file passed with `--executor-record`: a forge init output or a merged package.
/// A file with none is refused — the reviewer meant it to establish something.
pub(crate) fn load_record_file(path: &Path) -> anyhow::Result<UpgradeExecutorsRecord> {
    let raw =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let root: toml::Value =
        toml::from_str(&raw).with_context(|| format!("parsing {} as TOML", path.display()))?;
    let records = records_in(&root, &path.display().to_string())?;
    anyhow::ensure!(
        !records.is_empty(),
        "{} carries no executor record: no [upgrade_executors] table at its root, under [core] or \
         under [ctms.*]",
        path.display()
    );
    Ok(records)
}

/// Adds `next` (read from `source`) to `into`. A record identical to one already held is the same
/// statement twice; a different one for the same executor is refused.
pub(crate) fn merge_records(
    into: &mut UpgradeExecutorsRecord,
    next: UpgradeExecutorsRecord,
    source: &str,
) -> anyhow::Result<()> {
    merge_one(
        &mut into.core_executor,
        next.core_executor,
        "core_executor",
        source,
    )?;
    merge_one(
        &mut into.coordinator,
        next.coordinator,
        "coordinator",
        source,
    )?;
    merge_one(
        &mut into.ctm_executor,
        next.ctm_executor,
        "ctm_executor",
        source,
    )?;
    Ok(())
}

fn merge_one<T: PartialEq + std::fmt::Debug>(
    into: &mut Option<T>,
    next: Option<T>,
    kind: &str,
    source: &str,
) -> anyhow::Result<()> {
    match (into.as_ref(), next) {
        (_, None) => {}
        (None, Some(next)) => *into = Some(next),
        (Some(held), Some(next)) if *held == next => {}
        (Some(held), Some(next)) => anyhow::bail!(
            "conflicting `{kind}` executor records: {source} records {next:?}, but an earlier \
             record says {held:?}. The review cannot tell which one describes the executor it \
             verifies — pass only the record of the run that deployed it"
        ),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{Address, B256};

    use crate::common::forge::scripts::upgrade_executors::{
        CoordinatorRecord, CoreExecutorRecord, CtmExecutorRecord,
    };

    fn core_record_toml(address: u8) -> String {
        format!(
            "[core_executor]\n\
             address = \"{}\"\n\
             create2_salt = \"{}\"\n\
             initial_owner = \"{}\"\n\
             proxy_admin = \"{}\"\n\
             [coordinator]\n\
             address = \"{}\"\n\
             create2_salt = \"{}\"\n\
             initial_owner = \"{}\"\n\
             core_executor = \"{}\"\n",
            Address::repeat_byte(address),
            B256::repeat_byte(0x5A),
            Address::repeat_byte(0x01),
            Address::repeat_byte(0x04),
            Address::repeat_byte(0xC0),
            B256::repeat_byte(0x5A),
            Address::repeat_byte(0x01),
            Address::repeat_byte(address),
        )
    }

    fn ctm_record_toml() -> String {
        format!(
            "[ctm_executor]\n\
             address = \"{}\"\n\
             create2_salt = \"{}\"\n\
             initial_owner = \"{}\"\n\
             chain_type_manager = \"{}\"\n\
             ctm_proxy_admin = \"{}\"\n\
             coordinator = \"{}\"\n",
            Address::repeat_byte(0xE0),
            B256::repeat_byte(0x6B),
            Address::repeat_byte(0x01),
            Address::repeat_byte(0x02),
            Address::repeat_byte(0x03),
            Address::repeat_byte(0xC0),
        )
    }

    /// Prefixes every table header of `body` with `prefix.` — the same record, nested.
    fn nested(prefix: &str, body: &str) -> String {
        body.replace("[core_executor]", &format!("[{prefix}.core_executor]"))
            .replace("[coordinator]", &format!("[{prefix}.coordinator]"))
            .replace("[ctm_executor]", &format!("[{prefix}.ctm_executor]"))
    }

    fn parse(body: &str) -> anyhow::Result<UpgradeExecutorsRecord> {
        records_in(&toml::from_str(body).unwrap(), "test.toml")
    }

    /// A forge init output carries its record at the root; a merged package under `[core]` and
    /// `[ctms.<key>]`. All three are found, and they merge into one set.
    #[test]
    fn records_are_found_at_the_root_under_core_and_under_each_ctm() {
        let root = parse(&nested("upgrade_executors", &core_record_toml(0xA0))).unwrap();
        assert_eq!(
            root.core_executor.as_ref().map(|r| r.address),
            Some(Address::repeat_byte(0xA0))
        );
        assert!(root.coordinator.is_some());
        assert!(root.ctm_executor.is_none());

        let package = parse(&format!(
            "{}{}",
            nested("core.upgrade_executors", &core_record_toml(0xA0)),
            nested("ctms.zksync_os.upgrade_executors", &ctm_record_toml())
        ))
        .unwrap();
        assert_eq!(
            package.core_executor,
            Some(CoreExecutorRecord {
                address: Address::repeat_byte(0xA0),
                create2_salt: B256::repeat_byte(0x5A),
                initial_owner: Address::repeat_byte(0x01),
                proxy_admin: Address::repeat_byte(0x04),
            })
        );
        assert_eq!(
            package.coordinator,
            Some(CoordinatorRecord {
                address: Address::repeat_byte(0xC0),
                create2_salt: B256::repeat_byte(0x5A),
                initial_owner: Address::repeat_byte(0x01),
                core_executor: Address::repeat_byte(0xA0),
            })
        );
        assert_eq!(
            package.ctm_executor,
            Some(CtmExecutorRecord {
                address: Address::repeat_byte(0xE0),
                create2_salt: B256::repeat_byte(0x6B),
                initial_owner: Address::repeat_byte(0x01),
                chain_type_manager: Address::repeat_byte(0x02),
                ctm_proxy_admin: Address::repeat_byte(0x03),
                coordinator: Address::repeat_byte(0xC0),
            })
        );
    }

    /// Forge writes addresses EIP-55 checksummed; they parse like lowercase ones.
    #[test]
    fn a_checksummed_record_parses() {
        let checksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
        let body =
            core_record_toml(0xA0).replace(&Address::repeat_byte(0x04).to_string(), checksummed);
        let record = parse(&nested("upgrade_executors", &body)).unwrap();
        assert_eq!(
            record.core_executor.unwrap().proxy_admin,
            checksummed.parse::<Address>().unwrap()
        );
    }

    #[test]
    fn a_package_without_records_has_none() {
        assert!(parse("[core.registry]\ncore_transition_addr = \"0x00\"\n")
            .unwrap()
            .is_empty());
    }

    /// The same record twice — a package and the init output it came from — is one statement.
    #[test]
    fn an_identical_duplicate_merges() {
        let mut merged = parse(&nested("upgrade_executors", &core_record_toml(0xA0))).unwrap();
        let again = parse(&nested("core.upgrade_executors", &core_record_toml(0xA0))).unwrap();
        merge_records(&mut merged, again, "again.toml").unwrap();
        assert_eq!(
            merged.core_executor.unwrap().address,
            Address::repeat_byte(0xA0)
        );
    }

    /// Two different records of one executor: the review cannot pick, so it refuses — whether the
    /// two sit in one file or arrive from two.
    #[test]
    fn conflicting_duplicates_are_refused() {
        let err = parse(&format!(
            "{}{}",
            nested("upgrade_executors", &core_record_toml(0xA0)),
            nested("core.upgrade_executors", &core_record_toml(0xA1))
        ))
        .unwrap_err()
        .to_string();
        assert!(err.contains("conflicting `core_executor`"), "{err}");

        let mut merged = parse(&nested("upgrade_executors", &core_record_toml(0xA0))).unwrap();
        let other = parse(&nested("upgrade_executors", &core_record_toml(0xA1))).unwrap();
        let err = merge_records(&mut merged, other, "other.toml")
            .unwrap_err()
            .to_string();
        assert!(err.contains("other.toml"), "{err}");
    }

    /// A field the format does not know is a constructor argument the derivation would ignore.
    #[test]
    fn an_unknown_field_is_refused() {
        let body = format!(
            "{}extra_argument = \"0x01\"\n",
            nested("upgrade_executors", &ctm_record_toml())
        );
        assert!(parse(&body).is_err());
    }

    #[test]
    fn a_record_file_without_any_record_is_refused() {
        let dir = std::env::temp_dir().join(format!(
            "protocol-ops-records-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("empty.toml");
        std::fs::write(&path, "[deployed_addresses]\n").unwrap();
        let err = load_record_file(&path).unwrap_err().to_string();
        assert!(err.contains("carries no executor record"), "{err}");

        let path = dir.join("init.toml");
        std::fs::write(&path, nested("upgrade_executors", &ctm_record_toml())).unwrap();
        assert!(load_record_file(&path).unwrap().ctm_executor.is_some());
    }
}
