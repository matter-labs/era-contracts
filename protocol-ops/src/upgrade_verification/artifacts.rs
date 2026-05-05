use std::{fs, path::Path};

use anyhow::Context;
use serde::Deserialize;

#[derive(Debug)]
pub(crate) struct EcosystemUpgradeArtifact {
    pub(crate) value: toml::Value,
    pub(crate) chain_upgrade_diamond_cut: String,
    pub(crate) contracts_config: ContractsConfig,
    pub(crate) governance_calls: GovernanceCalls,
}

impl EcosystemUpgradeArtifact {
    pub(crate) fn read(path: &Path) -> anyhow::Result<Self> {
        let content = fs::read_to_string(path).with_context(|| {
            format!("Failed to read ecosystem upgrade TOML: {}", path.display())
        })?;
        let value = toml::from_str(&content).with_context(|| {
            format!("Failed to parse ecosystem upgrade TOML: {}", path.display())
        })?;
        let fields: EcosystemUpgradeArtifactFields =
            toml::from_str(&content).with_context(|| {
                format!("Failed to parse ecosystem upgrade TOML: {}", path.display())
            })?;

        Ok(Self {
            value,
            chain_upgrade_diamond_cut: fields.chain_upgrade_diamond_cut,
            contracts_config: fields.contracts_config,
            governance_calls: fields.governance_calls,
        })
    }
}

#[derive(Debug, Deserialize)]
struct EcosystemUpgradeArtifactFields {
    chain_upgrade_diamond_cut: String,
    contracts_config: ContractsConfig,
    governance_calls: GovernanceCalls,
}

#[derive(Debug, Deserialize)]
pub(crate) struct ContractsConfig {
    pub(crate) diamond_cut_data: String,
    pub(crate) force_deployments_data: String,
    pub(crate) new_protocol_version: u64,
    pub(crate) old_protocol_version: u64,
}

#[derive(Debug, Deserialize)]
pub(crate) struct GovernanceCalls {
    pub(crate) stage0_calls: String,
    pub(crate) stage1_calls: String,
    pub(crate) stage2_calls: String,
}
