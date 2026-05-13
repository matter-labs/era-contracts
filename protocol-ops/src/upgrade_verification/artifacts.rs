use std::{fs, path::Path};

use anyhow::Context;
use serde::Deserialize;
use toml::value::Table;

#[derive(Debug)]
pub(crate) struct EcosystemUpgradeArtifact {
    /// Synthetic flat view used by single-CTM-aware verifier code: the
    /// merged ecosystem TOML's top-level `[governance_calls]` plus a
    /// deep-merge of `[core]` and the *first* `[ctms.<flavor>]` section.
    /// Code that needs per-CTM resolution should iterate [`Self::ctms`]
    /// directly.
    pub(crate) value: toml::Value,
    /// Diamond cut from the first `[ctms.<flavor>]` section. Multi-CTM
    /// callers must walk [`Self::ctms`] for per-CTM cuts.
    pub(crate) chain_upgrade_diamond_cut: String,
    /// Contracts config from the first `[ctms.<flavor>]` section.
    pub(crate) contracts_config: ContractsConfig,
    pub(crate) governance_calls: GovernanceCalls,
    /// One entry per `[ctms.<flavor>]` section in the merged TOML, in the
    /// order encountered. `era` always sorts before `zksync_os` for
    /// deterministic ordering.
    pub(crate) ctms: Vec<CtmArtifact>,
    /// Optional `[new_gateway]` table from `write_merged_ecosystem_toml` —
    /// present when the env config carried a `[new_gateway]` block. Stage-2
    /// verification uses this to know how many GW bring-up calls to expect
    /// past the canonical 5 (unpauseMigration + per-CTM checks) and which
    /// deployed-GW-CTM address to cross-check.
    pub(crate) new_gateway: Option<NewGatewayArtifact>,
}

#[derive(Debug)]
pub(crate) struct NewGatewayArtifact {
    /// `gateway_state_transition.chain_type_manager_proxy_addr` — the L1
    /// address of the deployed GW CTM. The `addChainTypeManager` L1→L2
    /// priority tx whose calldata gets baked into stage 2 references this
    /// address as the CTM being added to the L2 Bridgehub on the gateway.
    pub(crate) gateway_chain_type_manager_addr: alloy::primitives::Address,
    /// Deployed GW RollupDAManager (L1 address). Stage-2 GW bring-up sends
    /// an `acceptOwnership` priority tx targeting this contract on L2 via
    /// the new gateway — used to cross-check the priority-tx's `dstAddress`.
    pub(crate) gateway_rollup_da_manager_addr: Option<alloy::primitives::Address>,
    /// Deployed GW ServerNotifier proxy (L1 address). Same use as above —
    /// the second `acceptOwnership` priority tx targets this contract.
    pub(crate) gateway_server_notifier_addr: Option<alloy::primitives::Address>,
    /// Raw `[new_gateway]` table, kept for downstream verifiers that want
    /// to read additional fields (multicall3_addr, validators, diamond cut)
    /// without re-parsing the artifact.
    #[allow(dead_code)]
    pub(crate) value: toml::Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CtmFlavor {
    Era,
    ZksyncOs,
}

impl CtmFlavor {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Era => "era",
            Self::ZksyncOs => "zksync_os",
        }
    }

    fn parse(label: &str) -> anyhow::Result<Self> {
        match label {
            "era" => Ok(Self::Era),
            "zksync_os" => Ok(Self::ZksyncOs),
            other => anyhow::bail!("unknown CTM flavor `{other}`; expected `era` or `zksync_os`"),
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

impl EcosystemUpgradeArtifact {
    pub(crate) fn read(path: &Path) -> anyhow::Result<Self> {
        let content = fs::read_to_string(path).with_context(|| {
            format!("Failed to read ecosystem upgrade TOML: {}", path.display())
        })?;
        Self::from_toml_str(&content)
            .with_context(|| format!("parsing ecosystem upgrade TOML: {}", path.display()))
    }

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

        // Deterministic ordering: era first, then zksync_os.
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

        // Build the flat backward-compat view: deep-merge `core` then the
        // first CTM section into a single top-level table. This keeps the
        // single-CTM-aware verifier code (address lookups against
        // `state_transition`, `deployed_addresses`, `upgrade_addresses`,
        // and top-level fields like `chain_upgrade_diamond_cut`) working
        // without per-call rewrites.
        let mut flat = Table::new();
        flat.insert(
            "governance_calls".to_string(),
            toml::Value::try_from(&governance_calls)
                .context("re-encoding governance_calls into flat view")?,
        );
        deep_merge_into(&mut flat, core_table.clone());
        let primary_table = match &ctms[0].value {
            toml::Value::Table(t) => t.clone(),
            _ => unreachable!("validated above"),
        };
        deep_merge_into(&mut flat, primary_table);

        // Legacy verifier code expects `deployed_addresses.{bridgehub,bridges}`
        // at top level (the pre-split single-file ecosystem TOML had them
        // duplicated under both `deployed_addresses.*` and `upgrade_addresses.*`).
        // The split prepare emits bridgehub/bridges sub-tables only under
        // `core.upgrade_addresses.*`, so synthesize the matching
        // `deployed_addresses.*` entries from there.
        if let Some(toml::Value::Table(core_upgrade)) = core_table.get("upgrade_addresses") {
            let dst_dep = flat
                .entry("deployed_addresses".to_string())
                .or_insert_with(|| toml::Value::Table(Table::new()));
            if let toml::Value::Table(dst_dep) = dst_dep {
                if let Some(toml::Value::Table(bh)) = core_upgrade.get("bridgehub") {
                    dst_dep
                        .entry("bridgehub".to_string())
                        .or_insert_with(|| toml::Value::Table(bh.clone()));
                }
                if let Some(toml::Value::Table(br)) = core_upgrade.get("bridges") {
                    dst_dep
                        .entry("bridges".to_string())
                        .or_insert_with(|| toml::Value::Table(br.clone()));
                }
            }
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
                let parse_required = |field: &str| -> anyhow::Result<alloy::primitives::Address> {
                    let raw = gst
                        .get(field)
                        .and_then(toml::Value::as_str)
                        .with_context(|| {
                            format!(
                                "[new_gateway.gateway_state_transition.{field}] is required when [new_gateway] is present"
                            )
                        })?;
                    use std::str::FromStr;
                    alloy::primitives::Address::parse_checksummed(raw, None)
                        .or_else(|_| alloy::primitives::Address::from_str(raw))
                        .with_context(|| format!("invalid address for `{field}`: `{raw}`"))
                };
                let parse_optional = |field: &str| -> Option<alloy::primitives::Address> {
                    let raw = gst.get(field).and_then(toml::Value::as_str)?;
                    use std::str::FromStr;
                    alloy::primitives::Address::parse_checksummed(raw, None)
                        .or_else(|_| alloy::primitives::Address::from_str(raw))
                        .ok()
                        .filter(|a| *a != alloy::primitives::Address::ZERO)
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

        Ok(Self {
            value: toml::Value::Table(flat),
            chain_upgrade_diamond_cut: ctms[0].chain_upgrade_diamond_cut.clone(),
            contracts_config: ctms[0].contracts_config.clone(),
            governance_calls,
            ctms,
            new_gateway,
        })
    }
}

fn expect_table(value: toml::Value, name: &str) -> anyhow::Result<Table> {
    match value {
        toml::Value::Table(t) => Ok(t),
        _ => anyhow::bail!("[{name}] must be a table"),
    }
}

/// Deep-merge `src` into `dst`. Sub-tables are recursed into; scalar /
/// non-table values from `src` overwrite `dst` on conflict.
fn deep_merge_into(dst: &mut Table, src: Table) {
    for (k, v) in src {
        match (dst.get_mut(&k), v) {
            (Some(toml::Value::Table(dst_inner)), toml::Value::Table(src_inner)) => {
                deep_merge_into(dst_inner, src_inner);
            }
            (_, v) => {
                dst.insert(k, v);
            }
        }
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
            asset_tracker_proxy_addr = "0x0000000000000000000000000000000000000001"

            [core.upgrade_addresses]
            native_token_vault_implementation_addr = "0x0000000000000000000000000000000000000002"

            [ctms.era]
            chain_upgrade_diamond_cut = "0xabcd"

            [ctms.era.contracts_config]
            diamond_cut_data = "0x"
            force_deployments_data = "0x"
            new_protocol_version = 2
            old_protocol_version = 1
            governance_upgrade_timer_initial_delay = 1200
            is_testnet = true

            [ctms.era.state_transition]
            chain_type_manager_proxy = "0x0000000000000000000000000000000000000003"
        "#;
        let a = EcosystemUpgradeArtifact::from_toml_str(toml).unwrap();
        assert_eq!(a.ctms.len(), 1);
        assert_eq!(a.ctms[0].flavor, CtmFlavor::Era);
        assert_eq!(a.chain_upgrade_diamond_cut, "0xabcd");
        // Flat view should expose top-level `state_transition` from the CTM
        // and `upgrade_addresses` from core.
        assert!(a.value.get("state_transition").is_some());
        assert!(a.value.get("upgrade_addresses").is_some());
        assert!(a.value.get("asset_tracker_proxy_addr").is_some());
    }

    #[test]
    fn parses_multi_ctm_artifact_in_deterministic_order() {
        let toml = r#"
            [governance_calls]
            stage0_calls = "0x"
            stage1_calls = "0x"
            stage2_calls = "0x"

            [core]

            [ctms.zksync_os]
            chain_upgrade_diamond_cut = "0xbb"
            [ctms.zksync_os.contracts_config]
            diamond_cut_data = "0x"
            force_deployments_data = "0x"
            new_protocol_version = 2
            old_protocol_version = 1
            governance_upgrade_timer_initial_delay = 0
            is_testnet = false

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
        let a = EcosystemUpgradeArtifact::from_toml_str(toml).unwrap();
        assert_eq!(a.ctms.len(), 2);
        assert_eq!(a.ctms[0].flavor, CtmFlavor::Era);
        assert_eq!(a.ctms[1].flavor, CtmFlavor::ZksyncOs);
        // The flat-view falls back to the first (era) CTM.
        assert_eq!(a.chain_upgrade_diamond_cut, "0xaa");
    }
}
