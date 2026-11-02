//! The deploy-time records a review re-derives construction from: the executors' and the
//! members'.
//!
//! An executor's address commits to its ORIGINAL constructor arguments — among them the owner it
//! was built for, which moves afterwards (a fresh ecosystem builds its executors for the deployer
//! and nominates governance). Re-deriving from the current owner therefore cannot tell a genuine
//! executor whose owner moved from a counterfeit; re-deriving from what the deploying run RECORDED
//! can ([`super::lifecycle`]). A member's address likewise commits to the constructor arguments
//! its immutables were written from, which nothing on chain answers for most members
//! ([`super::member_construction`]).
//!
//! An executor record sits wherever a run that deployed executors wrote its `[upgrade_executors]`
//! table: at the root of a forge init output (`DeployL1CoreContracts`, `DeployCTM`), and under
//! `[core]` / `[ctms.<key>]` of a merged prepare package (v35's bootstrap `CoreUpgrade_v35`, `CTMUpgrade_v35`). A
//! member record is a prepare's `[member_deployments]` table, found at the same three places.
//! Records from several places merge into one set; two DIFFERENT records of the same object are
//! refused, since the review cannot say which one describes the object it verifies.

use std::path::Path;

use anyhow::Context;

use crate::common::forge::scripts::member_deployments::{self, MemberDeployments};
use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;

/// Every `table` in `root` — at the root, under `[core]` and under each `[ctms.<key>]` — with the
/// location it sits at.
fn tables_named<'a>(root: &'a toml::Value, table: &str) -> Vec<(String, &'a toml::Value)> {
    let mut locations: Vec<(String, &toml::Value)> = Vec::new();
    if let Some(value) = root.get(table) {
        locations.push((format!("[{table}]"), value));
    }
    if let Some(value) = root.get("core").and_then(|core| core.get(table)) {
        locations.push((format!("[core.{table}]"), value));
    }
    if let Some(ctms) = root.get("ctms").and_then(toml::Value::as_table) {
        for (key, ctm) in ctms {
            if let Some(value) = ctm.get(table) {
                locations.push((format!("[ctms.{key}.{table}]"), value));
            }
        }
    }
    locations
}

/// Every `[upgrade_executors]` table in `root` — at the root, under `[core]` and under each
/// `[ctms.<key>]` — merged into one set. `source` names the file in errors.
pub(crate) fn records_in(
    root: &toml::Value,
    source: &str,
) -> anyhow::Result<UpgradeExecutorsRecord> {
    let locations = tables_named(root, "upgrade_executors");
    let mut merged = UpgradeExecutorsRecord::default();
    for (location, value) in locations {
        let record: UpgradeExecutorsRecord = value.clone().try_into().with_context(|| {
            format!("{source}: {location} does not decode as an executor record")
        })?;
        merge_records(&mut merged, record, &format!("{source} {location}"))?;
    }
    Ok(merged)
}

/// Every `[member_deployments]` table in `root` — at the root, under `[core]` and under each
/// `[ctms.<key>]` — merged into one set. `source` names the file in errors. A package without
/// any has no records: every member it newly installs is then unrecorded, which the review
/// reports.
pub(crate) fn member_records_in(
    root: &toml::Value,
    source: &str,
) -> anyhow::Result<MemberDeployments> {
    let mut merged = MemberDeployments::new();
    for (location, value) in tables_named(root, "member_deployments") {
        let entries = member_deployments::parse_table(value).with_context(|| {
            format!("{source}: {location} does not decode as member deployment records")
        })?;
        for (address, record) in entries {
            match merged.get(&address) {
                None => {
                    merged.insert(address, record);
                }
                Some(held) if *held == record => {}
                Some(held) => anyhow::bail!(
                    "conflicting member deployment records for {address}: {source} {location} \
                     records {record:?}, but an earlier record says {held:?}. The review cannot \
                     tell which one describes the deployed member"
                ),
            }
        }
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

    use crate::common::forge::scripts::upgrade_executors::{CoreExecutorRecord, CtmExecutorRecord};

    fn core_record_toml(address: u8) -> String {
        format!(
            "[core_executor]\n\
             address = \"{}\"\n\
             create2_salt = \"{}\"\n\
             initial_owner = \"{}\"\n\
             proxy_admin = \"{}\"\n",
            Address::repeat_byte(address),
            B256::repeat_byte(0x5A),
            Address::repeat_byte(0x01),
            Address::repeat_byte(0x04),
        )
    }

    fn ctm_record_toml() -> String {
        format!(
            "[ctm_executor]\n\
             address = \"{}\"\n\
             create2_salt = \"{}\"\n\
             initial_owner = \"{}\"\n\
             chain_type_manager = \"{}\"\n\
             ctm_proxy_admin = \"{}\"\n",
            Address::repeat_byte(0xE0),
            B256::repeat_byte(0x6B),
            Address::repeat_byte(0x01),
            Address::repeat_byte(0x02),
            Address::repeat_byte(0x03),
        )
    }

    /// Prefixes every table header of `body` with `prefix.` — the same record, nested.
    fn nested(prefix: &str, body: &str) -> String {
        body.replace("[core_executor]", &format!("[{prefix}.core_executor]"))
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
            package.ctm_executor,
            Some(CtmExecutorRecord {
                address: Address::repeat_byte(0xE0),
                create2_salt: B256::repeat_byte(0x6B),
                initial_owner: Address::repeat_byte(0x01),
                chain_type_manager: Address::repeat_byte(0x02),
                ctm_proxy_admin: Address::repeat_byte(0x03),
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

    /// The executors no longer answer to a coordinator, so a record of one — a whole
    /// `[coordinator]` table, or a CTM executor's constructor `coordinator` — describes a
    /// deployment this build does not produce, and is refused rather than read with it dropped.
    #[test]
    fn a_coordinator_record_is_refused() {
        let with_table = format!(
            "{}[upgrade_executors.coordinator]\n\
             address = \"{}\"\n\
             create2_salt = \"{}\"\n\
             initial_owner = \"{}\"\n\
             core_executor = \"{}\"\n",
            nested("upgrade_executors", &core_record_toml(0xA0)),
            Address::repeat_byte(0xC0),
            B256::repeat_byte(0x5A),
            Address::repeat_byte(0x01),
            Address::repeat_byte(0xA0),
        );
        let err = format!("{:#}", parse(&with_table).unwrap_err());
        assert!(
            err.contains("does not decode as an executor record"),
            "{err}"
        );
        assert!(err.contains("coordinator"), "{err}");

        let with_field = format!(
            "{}coordinator = \"{}\"\n",
            nested("upgrade_executors", &ctm_record_toml()),
            Address::repeat_byte(0xC0)
        );
        let err = format!("{:#}", parse(&with_field).unwrap_err());
        assert!(err.contains("coordinator"), "{err}");
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

    // ───────────────────────── member deployment records ─────────────────────────

    fn member_toml(prefix: &str, key: &str, contract: &str) -> String {
        format!(
            "[{prefix}member_deployments.{key}]\n\
             contract = \"{contract}\"\n\
             create2_factory = \"0x4e59b44847b379578588920cA78FbF26c0B4956C\"\n\
             create2_salt = \"{}\"\n\
             constructor_args = \"0x\"\n",
            B256::repeat_byte(0x5A)
        )
    }

    fn members(body: &str) -> anyhow::Result<MemberDeployments> {
        member_records_in(&toml::from_str(body).unwrap(), "test.toml")
    }

    const CHECKSUMMED: &str = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";

    /// A prepare output carries its records at the root; a merged package under `[core]` and each
    /// `[ctms.<key>]`. All are found and merge into one set.
    #[test]
    fn member_records_are_found_at_the_root_under_core_and_under_each_ctm() {
        let a = Address::repeat_byte(0xA0).to_string();
        let b = Address::repeat_byte(0xB0).to_string();
        let c = Address::repeat_byte(0xC0).to_string();
        let records = members(&format!(
            "{}{}{}",
            member_toml("", &a, "AdminFacet"),
            member_toml("core.", &b, "L1MessageRoot"),
            member_toml("ctms.zksync_os.", &c, "DefaultUpgrade")
        ))
        .unwrap();
        assert_eq!(records.len(), 3);
        let record = &records[&Address::repeat_byte(0xB0)];
        assert_eq!(record.contract, "L1MessageRoot");
        assert_eq!(record.create2_salt, B256::repeat_byte(0x5A));
        assert!(record.constructor_args.is_empty());
    }

    /// Forge writes the key EIP-55 checksummed; the same deployment recorded twice — under two
    /// spellings of its address, or at two places — is one statement.
    #[test]
    fn an_identical_member_record_duplicate_merges() {
        let records = members(&format!(
            "{}{}",
            member_toml("core.", CHECKSUMMED, "AdminFacet"),
            member_toml("ctms.zksync_os.", &CHECKSUMMED.to_lowercase(), "AdminFacet")
        ))
        .unwrap();
        assert_eq!(records.len(), 1);
        assert!(records.contains_key(&CHECKSUMMED.parse::<Address>().unwrap()));
    }

    #[test]
    fn conflicting_member_records_are_refused() {
        let err = members(&format!(
            "{}{}",
            member_toml("core.", CHECKSUMMED, "AdminFacet"),
            member_toml("ctms.zksync_os.", CHECKSUMMED, "GettersFacet")
        ))
        .unwrap_err()
        .to_string();
        assert!(
            err.contains("conflicting member deployment records"),
            "{err}"
        );
    }

    /// A field the format does not know would be an input the derivation ignores.
    #[test]
    fn an_unknown_record_field_is_refused() {
        let body = format!(
            "{}initializer = \"0x\"\n",
            member_toml("", CHECKSUMMED, "AdminFacet")
        );
        let err = format!("{:#}", members(&body).unwrap_err());
        assert!(err.contains("does not decode"), "{err}");
    }

    #[test]
    fn a_key_that_is_no_address_is_refused() {
        let err = format!(
            "{:#}",
            members(&member_toml("", "admin_facet", "AdminFacet")).unwrap_err()
        );
        assert!(err.contains("is not an address"), "{err}");
    }

    #[test]
    fn a_package_without_member_records_has_none() {
        assert!(
            members("[core.registry]\ncore_transition_addr = \"0x00\"\n")
                .unwrap()
                .is_empty()
        );
        // The table an empty run writes.
        assert!(members("[ctms.zksync_os.member_deployments]\n")
            .unwrap()
            .is_empty());
    }
}
