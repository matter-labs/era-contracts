use std::str::FromStr;

use alloy::primitives::Address;
use anyhow::Context;
use serde::Deserialize;
use toml::value::Table;

#[derive(Debug)]
pub(crate) struct EcosystemUpgradeArtifact {
    /// Raw `[core]` table from the merged ecosystem TOML.
    pub(crate) core: toml::Value,
    pub(crate) governance_calls: GovernanceCalls,
    /// One entry per `[ctms.<flavor>]` section in the merged TOML, in
    /// sorted-key order. Only the `zksync_os` flavor is supported on this
    /// OS-only build; `[ctms.era]` input is rejected at parse time.
    pub(crate) ctms: Vec<CtmArtifact>,
    /// Optional `[new_gateway]` table from `write_merged_ecosystem_toml` —
    /// present when the env config carried a `[new_gateway]` block. Stage-2
    /// verification uses this to know how many GW bring-up calls to expect
    /// past the canonical 5 (unpauseMigration + per-CTM checks) and which
    /// deployed-GW-CTM address to cross-check.
    pub(crate) new_gateway: Option<NewGatewayArtifact>,
    /// Optional `[zk_governance]` table emitted on PUH-governed v31 upgrades.
    /// It names the four zk-governance contracts deployed via L1 CREATE2 so
    /// provenance verification can stay decoupled from stage-0 calldata
    /// decoding; stage-0 verification binds decoded calls back to these values.
    pub(crate) zk_governance: Option<ZkGovernanceArtifact>,
    /// Raw top-level `[misc]` table for shared metadata that does not belong to
    /// core or a particular CTM.
    pub(crate) misc: toml::Value,
}

#[derive(Debug)]
pub(crate) struct NewGatewayArtifact {
    /// `gateway_state_transition.chain_type_manager_proxy_addr` — the L1
    /// address of the deployed GW CTM. The `addChainTypeManager` L1→L2
    /// priority tx whose calldata gets baked into stage 2 references this
    /// address as the CTM being added to the L2 Bridgehub on the gateway.
    pub(crate) gateway_chain_type_manager_addr: Address,
    /// Deployed GW RollupDAManager (L1 address). Stage-2 GW bring-up sends
    /// an `acceptOwnership` priority tx targeting this contract on L2 via
    /// the new gateway — used to cross-check the priority-tx's `dstAddress`.
    pub(crate) gateway_rollup_da_manager_addr: Option<Address>,
    /// Deployed GW ServerNotifier proxy (L1 address). Same use as above —
    /// the second `acceptOwnership` priority tx targets this contract.
    pub(crate) gateway_server_notifier_addr: Option<Address>,
    /// Raw `[new_gateway]` table, kept for downstream verifiers that want
    /// to read additional fields (multicall3_addr, validators, diamond cut)
    /// without re-parsing the artifact.
    #[allow(dead_code)]
    pub(crate) value: toml::Value,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ZkGovernanceArtifact {
    pub(crate) new_puh_impl: Address,
    pub(crate) new_guardians: Address,
    pub(crate) new_security_council: Address,
    pub(crate) new_emergency_upgrade_board: Address,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CtmFlavor {
    ZksyncOs,
}

impl CtmFlavor {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::ZksyncOs => "zksync_os",
        }
    }

    fn parse(label: &str) -> anyhow::Result<Self> {
        match label {
            "zksync_os" => Ok(Self::ZksyncOs),
            "era" => anyhow::bail!(
                "[ctms.era] is not supported: Era CTM verification was removed from this \
                 ZKsync OS-only build; only `[ctms.zksync_os]` can be verified"
            ),
            other => anyhow::bail!("unknown CTM flavor `{other}`; expected `zksync_os`"),
        }
    }
}

#[derive(Debug)]
pub(crate) struct CtmArtifact {
    pub(crate) flavor: CtmFlavor,
    pub(crate) chain_upgrade_diamond_cut: String,
    pub(crate) contracts_config: ContractsConfig,
    /// The raw `[ctms.<flavor>]` table, for per-CTM address lookups.
    pub(crate) value: toml::Value,
}

/// Resolves a nested address from a TOML value. `scope` is used only for
/// error messages (e.g. `"core"`, `"misc"`, `"ctms.era"`); `path` is the
/// chain of keys to walk into `value`.
pub(crate) fn required_address_in_value(
    value: &toml::Value,
    scope: &str,
    path: &[&str],
) -> anyhow::Result<Address> {
    let path_label = format!("{scope}.{}", path.join("."));
    let mut current = value;
    for segment in path {
        let Some(next) = current.get(*segment) else {
            anyhow::bail!("{path_label} is required");
        };
        current = next;
    }

    let Some(raw) = current.as_str() else {
        anyhow::bail!("{path_label} must be an address string");
    };

    raw.parse::<Address>()
        .with_context(|| format!("{path_label} is not a valid address"))
}

impl EcosystemUpgradeArtifact {
    pub(crate) fn from_toml_str(content: &str) -> anyhow::Result<Self> {
        let mut root: Table =
            toml::from_str(content).context("Failed to parse ecosystem upgrade TOML as table")?;

        let governance_calls: GovernanceCalls = root
            .remove("governance_calls")
            .context("missing top-level [governance_calls] table")?
            .try_into()
            .context("invalid [governance_calls] table")?;

        let core_value = root
            .remove("core")
            .context("missing top-level [core] table")?;
        let core_table = expect_table(core_value, "core")?;

        let ctms_table = expect_table(
            root.remove("ctms")
                .context("missing top-level [ctms] table")?,
            "ctms",
        )?;
        if ctms_table.is_empty() {
            anyhow::bail!("[ctms] must contain at least one CTM section");
        }

        // Deterministic ordering by sorted section key.
        let mut flavor_keys: Vec<String> = ctms_table.keys().cloned().collect();
        flavor_keys.sort();

        let mut ctms = Vec::with_capacity(flavor_keys.len());
        for key in &flavor_keys {
            let flavor = CtmFlavor::parse(key)?;
            let raw = ctms_table.get(key).expect("present, just iterated").clone();
            let table = match &raw {
                toml::Value::Table(t) => t.clone(),
                _ => anyhow::bail!("[ctms.{key}] must be a table"),
            };
            let chain_upgrade_diamond_cut = table
                .get("chain_upgrade_diamond_cut")
                .and_then(toml::Value::as_str)
                .with_context(|| {
                    format!("[ctms.{key}].chain_upgrade_diamond_cut is required and must be a hex string")
                })?
                .to_string();
            let contracts_config: ContractsConfig = table
                .get("contracts_config")
                .cloned()
                .with_context(|| format!("[ctms.{key}.contracts_config] is required"))?
                .try_into()
                .with_context(|| format!("invalid [ctms.{key}.contracts_config]"))?;
            ctms.push(CtmArtifact {
                flavor,
                chain_upgrade_diamond_cut,
                contracts_config,
                value: raw,
            });
        }

        // `[new_gateway]` is optional. Its presence flags GW-bring-up stage-2
        // calls — and we extract the deployed GW CTM proxy address while
        // we're here so the stage-2 verifier doesn't have to re-walk the
        // toml tree later.
        let new_gateway = match root.remove("new_gateway") {
            Some(value) => {
                let table = expect_table(value, "new_gateway")?;
                let gst = table
                    .get("gateway_state_transition")
                    .and_then(toml::Value::as_table)
                    .context(
                        "[new_gateway.gateway_state_transition] is required when [new_gateway] is present",
                    )?;
                let parse_required = |field: &str| -> anyhow::Result<Address> {
                    let raw = gst
                        .get(field)
                        .and_then(toml::Value::as_str)
                        .with_context(|| {
                            format!(
                                "[new_gateway.gateway_state_transition.{field}] is required when [new_gateway] is present"
                            )
                        })?;
                    Address::parse_checksummed(raw, None)
                        .or_else(|_| Address::from_str(raw))
                        .with_context(|| format!("invalid address for `{field}`: `{raw}`"))
                };
                let parse_optional = |field: &str| -> Option<Address> {
                    let raw = gst.get(field).and_then(toml::Value::as_str)?;
                    Address::parse_checksummed(raw, None)
                        .or_else(|_| Address::from_str(raw))
                        .ok()
                        .filter(|a| *a != Address::ZERO)
                };
                Some(NewGatewayArtifact {
                    gateway_chain_type_manager_addr: parse_required(
                        "chain_type_manager_proxy_addr",
                    )?,
                    gateway_rollup_da_manager_addr: parse_optional("rollup_da_manager_addr"),
                    gateway_server_notifier_addr: parse_optional("server_notifier_proxy_addr"),
                    value: toml::Value::Table(table),
                })
            }
            None => None,
        };

        let zk_governance = match root.remove("zk_governance") {
            Some(value) => {
                let table = expect_table(value, "zk_governance")?;
                let value = toml::Value::Table(table);
                Some(ZkGovernanceArtifact {
                    new_puh_impl: required_address_in_value(
                        &value,
                        "zk_governance",
                        &["new_puh_impl"],
                    )?,
                    new_guardians: required_address_in_value(
                        &value,
                        "zk_governance",
                        &["new_guardians"],
                    )?,
                    new_security_council: required_address_in_value(
                        &value,
                        "zk_governance",
                        &["new_security_council"],
                    )?,
                    new_emergency_upgrade_board: required_address_in_value(
                        &value,
                        "zk_governance",
                        &["new_emergency_upgrade_board"],
                    )?,
                })
            }
            None => None,
        };

        let misc = match root.remove("misc") {
            Some(value) => toml::Value::Table(expect_table(value, "misc")?),
            None => toml::Value::Table(Table::new()),
        };

        Ok(Self {
            core: toml::Value::Table(core_table),
            governance_calls,
            ctms,
            new_gateway,
            zk_governance,
            misc,
        })
    }
}

fn expect_table(value: toml::Value, name: &str) -> anyhow::Result<Table> {
    match value {
        toml::Value::Table(t) => Ok(t),
        _ => anyhow::bail!("[{name}] must be a table"),
    }
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
pub(crate) struct ContractsConfig {
    pub(crate) diamond_cut_data: String,
    pub(crate) force_deployments_data: String,
    pub(crate) new_protocol_version: u64,
    pub(crate) old_protocol_version: u64,
    pub(crate) governance_upgrade_timer_initial_delay: u64,
    pub(crate) is_testnet: bool,
}

#[derive(Debug, Deserialize, serde::Serialize)]
pub(crate) struct GovernanceCalls {
    pub(crate) stage0_calls: String,
    pub(crate) stage1_calls: String,
    pub(crate) stage2_calls: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_single_ctm_artifact() {
        let toml = r#"
            [governance_calls]
            stage0_calls = "0x"
            stage1_calls = "0x"
            stage2_calls = "0x"

            [core]
            deployer_addr = "0x0000000000000000000000000000000000000001"

            [core.upgrade_addresses]
            native_token_vault_implementation_addr = "0x0000000000000000000000000000000000000002"

            [ctms.zksync_os]
            chain_upgrade_diamond_cut = "0xabcd"

            [ctms.zksync_os.contracts_config]
            diamond_cut_data = "0x"
            force_deployments_data = "0x"
            new_protocol_version = 2
            old_protocol_version = 1
            governance_upgrade_timer_initial_delay = 1200
            is_testnet = true

            [ctms.zksync_os.state_transition]
            chain_type_manager_proxy = "0x0000000000000000000000000000000000000003"
        "#;
        let a = EcosystemUpgradeArtifact::from_toml_str(toml).unwrap();
        assert_eq!(a.ctms.len(), 1);
        assert_eq!(a.ctms[0].flavor, CtmFlavor::ZksyncOs);
        assert_eq!(a.ctms[0].chain_upgrade_diamond_cut, "0xabcd");
        assert!(a.core.get("state_transition").is_none());
        assert!(a.core.get("upgrade_addresses").is_some());
        assert!(a.core.get("deployer_addr").is_some());
    }

    #[test]
    fn rejects_era_ctm_section_with_clear_error() {
        let toml = r#"
            [governance_calls]
            stage0_calls = "0x"
            stage1_calls = "0x"
            stage2_calls = "0x"

            [core]

            [ctms.era]
            chain_upgrade_diamond_cut = "0xaa"
            [ctms.era.contracts_config]
            diamond_cut_data = "0x"
            force_deployments_data = "0x"
            new_protocol_version = 2
            old_protocol_version = 1
            governance_upgrade_timer_initial_delay = 0
            is_testnet = false
        "#;
        let err = EcosystemUpgradeArtifact::from_toml_str(toml).unwrap_err();
        assert!(
            format!("{err:#}").contains("[ctms.era] is not supported"),
            "unexpected error: {err:#}"
        );
    }

    #[test]
    fn parses_zk_governance_metadata() {
        let toml = r#"
            [governance_calls]
            stage0_calls = "0x"
            stage1_calls = "0x"
            stage2_calls = "0x"

            [core]

            [ctms.zksync_os]
            chain_upgrade_diamond_cut = "0xaa"
            [ctms.zksync_os.contracts_config]
            diamond_cut_data = "0x"
            force_deployments_data = "0x"
            new_protocol_version = 2
            old_protocol_version = 1
            governance_upgrade_timer_initial_delay = 0
            is_testnet = false

            [zk_governance]
            new_puh_impl = "0x0000000000000000000000000000000000000001"
            new_guardians = "0x0000000000000000000000000000000000000002"
            new_security_council = "0x0000000000000000000000000000000000000003"
            new_emergency_upgrade_board = "0x0000000000000000000000000000000000000004"
        "#;
        let artifact = EcosystemUpgradeArtifact::from_toml_str(toml).unwrap();
        let metadata = artifact.zk_governance.unwrap();
        assert_eq!(
            metadata.new_puh_impl,
            "0x0000000000000000000000000000000000000001"
                .parse::<Address>()
                .unwrap()
        );
        assert_eq!(
            metadata.new_guardians,
            "0x0000000000000000000000000000000000000002"
                .parse::<Address>()
                .unwrap()
        );
        assert_eq!(
            metadata.new_security_council,
            "0x0000000000000000000000000000000000000003"
                .parse::<Address>()
                .unwrap()
        );
        assert_eq!(
            metadata.new_emergency_upgrade_board,
            "0x0000000000000000000000000000000000000004"
                .parse::<Address>()
                .unwrap()
        );
    }
}
