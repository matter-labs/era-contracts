use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::Context;
use serde::Deserialize;

#[derive(Debug)]
pub(crate) struct PreparedUpgradeArtifacts {
    pub(crate) ecosystem: EcosystemUpgradeArtifact,
    pub(crate) core: ComponentUpgradeArtifact,
    pub(crate) ctm: ComponentUpgradeArtifact,
}

impl PreparedUpgradeArtifacts {
    pub(crate) fn read(
        ecosystem_toml: &Path,
        core_toml: &Path,
        ctm_toml: &Path,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            ecosystem: read_ecosystem_upgrade_artifact(ecosystem_toml)?,
            core: read_component_upgrade_artifact("core", core_toml)?,
            ctm: read_component_upgrade_artifact("ctm", ctm_toml)?,
        })
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct EcosystemUpgradeArtifact {
    pub(crate) chain_upgrade_diamond_cut: String,
    pub(crate) governance_calls: GovernanceCalls,
}

#[derive(Debug, Deserialize)]
pub(crate) struct GovernanceCalls {
    pub(crate) stage0_calls: String,
    pub(crate) stage1_calls: String,
    pub(crate) stage2_calls: String,
}

#[derive(Debug)]
pub(crate) struct ComponentUpgradeArtifact {
    pub(crate) name: &'static str,
    pub(crate) path: PathBuf,
    pub(crate) value: toml::Value,
}

fn read_ecosystem_upgrade_artifact(path: &Path) -> anyhow::Result<EcosystemUpgradeArtifact> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("Failed to read ecosystem upgrade TOML: {}", path.display()))?;
    toml::from_str(&content)
        .with_context(|| format!("Failed to parse ecosystem upgrade TOML: {}", path.display()))
}

fn read_component_upgrade_artifact(
    name: &'static str,
    path: &Path,
) -> anyhow::Result<ComponentUpgradeArtifact> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("Failed to read {name} upgrade TOML: {}", path.display()))?;
    let value = toml::from_str(&content)
        .with_context(|| format!("Failed to parse {name} upgrade TOML: {}", path.display()))?;

    Ok(ComponentUpgradeArtifact {
        name,
        path: path.to_path_buf(),
        value,
    })
}
