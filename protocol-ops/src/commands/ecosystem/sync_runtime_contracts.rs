//! `protocol_ops ecosystem sync-runtime-contracts`
//!
//! Propagates post-upgrade addresses from `ecosystem upgrade-prepare`'s
//! output TOML into a zkstack workspace's runtime contract configs. Replaces
//! the per-deployment `update-permanent-values.sh`-style sed glue that
//! downstream upgrade harnesses were carrying.
//!
//! Currently only `l1_bytecodes_supplier_addr` changes during a v31 Era
//! upgrade. If future upgrades change additional runtime fields, extend
//! [`SYNCED_FIELDS`] below and the corresponding TOML lookup.

use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::logger;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct SyncRuntimeContractsArgs {
    /// Path to the upgrade output TOML, typically
    /// `<contracts>/l1-contracts/script-out/v31-upgrade-ecosystem.toml`,
    /// emitted by `ecosystem upgrade-prepare`.
    #[clap(long)]
    pub upgrade_output_toml: PathBuf,

    /// Root of the zkstack workspace whose runtime contracts.yaml files
    /// should be patched. The ecosystem-wide `configs/contracts.yaml` and
    /// every `chains/<name>/configs/contracts.yaml` are updated.
    #[clap(long)]
    pub zkstack_config_dir: PathBuf,
}

/// Fields that the v31 ecosystem upgrade redeploys and therefore must be
/// re-pinned in runtime configs. Extend with `(toml-dotted-path,
/// runtime-yaml-leaf-key)` tuples if future upgrades introduce more.
const SYNCED_FIELDS: &[(&[&str], &str)] = &[(
    &["state_transition", "bytecodes_supplier_addr"],
    "l1_bytecodes_supplier_addr",
)];

pub async fn run(args: SyncRuntimeContractsArgs) -> anyhow::Result<()> {
    let toml_str = std::fs::read_to_string(&args.upgrade_output_toml)
        .with_context(|| format!("read {}", args.upgrade_output_toml.display()))?;
    let toml: toml::Value = toml::from_str(&toml_str)
        .with_context(|| format!("parse {}", args.upgrade_output_toml.display()))?;

    let target_yamls = collect_runtime_yamls(&args.zkstack_config_dir)?;
    if target_yamls.is_empty() {
        anyhow::bail!(
            "no runtime contracts.yaml files found under {} \
             (expected configs/contracts.yaml and/or chains/*/configs/contracts.yaml)",
            args.zkstack_config_dir.display()
        );
    }

    for (toml_path, yaml_key) in SYNCED_FIELDS {
        let new_value = lookup_toml_string(&toml, toml_path).with_context(|| {
            format!(
                "missing or non-string `{}` in {}",
                toml_path.join("."),
                args.upgrade_output_toml.display()
            )
        })?;
        anyhow::ensure!(
            !new_value.is_empty() && new_value != "0x0000000000000000000000000000000000000000",
            "upgrade output's {} is the zero address — refusing to propagate",
            toml_path.join(".")
        );
        logger::info(format!("Syncing {yaml_key} = {new_value}"));
        for yaml in &target_yamls {
            patch_yaml_field(yaml, yaml_key, &new_value)?;
            logger::info(format!("  patched {}", yaml.display()));
        }
    }

    logger::success(format!(
        "Synced {} field(s) across {} runtime config(s)",
        SYNCED_FIELDS.len(),
        target_yamls.len()
    ));
    Ok(())
}

/// Discover every runtime contracts.yaml in a zkstack workspace:
/// the ecosystem-wide `configs/contracts.yaml` plus each
/// `chains/<name>/configs/contracts.yaml`.
fn collect_runtime_yamls(workspace: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut yamls = Vec::new();
    let eco = workspace.join("configs/contracts.yaml");
    if eco.exists() {
        yamls.push(eco);
    }
    let chains_dir = workspace.join("chains");
    if chains_dir.exists() {
        for entry in std::fs::read_dir(&chains_dir)
            .with_context(|| format!("read {}", chains_dir.display()))?
        {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let chain_yaml = entry.path().join("configs/contracts.yaml");
            if chain_yaml.exists() {
                yamls.push(chain_yaml);
            }
        }
    }
    Ok(yamls)
}

fn lookup_toml_string(value: &toml::Value, path: &[&str]) -> Option<String> {
    let mut node = value;
    for key in path {
        node = node.get(key)?;
    }
    node.as_str().map(|s| s.to_string())
}

/// Replace the value of the first line whose stripped-leading-whitespace
/// content begins with `<field>:`. Preserves indentation, comments, and
/// the rest of the file. Mirrors the per-line `sed -i` patching that
/// downstream consumers had been doing in shell.
fn patch_yaml_field(path: &Path, field: &str, new_value: &str) -> anyhow::Result<()> {
    let content =
        std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let key_token = format!("{field}:");
    let mut found = false;
    let mut out = String::with_capacity(content.len());
    for line in content.lines() {
        if !found {
            let trimmed = line.trim_start();
            if trimmed
                .strip_prefix(&key_token)
                .is_some_and(|rest| rest.is_empty() || rest.starts_with(char::is_whitespace))
            {
                let indent = &line[..line.len() - trimmed.len()];
                out.push_str(indent);
                out.push_str(&key_token);
                out.push(' ');
                out.push_str(new_value);
                found = true;
                out.push('\n');
                continue;
            }
        }
        out.push_str(line);
        out.push('\n');
    }
    if !found {
        anyhow::bail!("field `{}:` not found in {}", field, path.display());
    }
    // Preserve absence of trailing newline if the original lacked one.
    if !content.ends_with('\n') {
        out.pop();
    }
    std::fs::write(path, out).with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_tmp_workspace(label: &str, files: &[(&str, &str)]) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("sync_runtime_test_{}_{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for (rel, content) in files {
            let abs = dir.join(rel);
            std::fs::create_dir_all(abs.parent().unwrap()).unwrap();
            std::fs::write(&abs, content).unwrap();
        }
        dir
    }

    #[test]
    fn patch_yaml_field_preserves_structure() {
        let yaml = "ecosystem_contracts:\n  l1_bytecodes_supplier_addr: 0xAAA\n  other: 0xBBB\n";
        let dir = write_tmp_workspace("patch_preserve", &[("c.yaml", yaml)]);
        patch_yaml_field(&dir.join("c.yaml"), "l1_bytecodes_supplier_addr", "0xCCC").unwrap();
        let result = std::fs::read_to_string(dir.join("c.yaml")).unwrap();
        assert_eq!(
            result,
            "ecosystem_contracts:\n  l1_bytecodes_supplier_addr: 0xCCC\n  other: 0xBBB\n"
        );
    }

    #[test]
    fn patch_yaml_field_missing_errors() {
        let dir = write_tmp_workspace("patch_missing", &[("c.yaml", "other: 0xBBB\n")]);
        let err = patch_yaml_field(&dir.join("c.yaml"), "l1_bytecodes_supplier_addr", "0xCCC")
            .unwrap_err();
        assert!(
            format!("{err:#}").contains("not found"),
            "expected 'not found' error"
        );
    }

    #[tokio::test]
    async fn run_patches_eco_and_each_chain() {
        let dir = write_tmp_workspace(
            "run_full",
            &[
                (
                    "configs/contracts.yaml",
                    "core_ecosystem_contracts:\n  l1_bytecodes_supplier_addr: 0xOLD\n",
                ),
                (
                    "chains/era/configs/contracts.yaml",
                    "ecosystem_contracts:\n  l1_bytecodes_supplier_addr: 0xOLD\n",
                ),
                (
                    "chains/gateway/configs/contracts.yaml",
                    "ecosystem_contracts:\n  l1_bytecodes_supplier_addr: 0xOLD\n",
                ),
                (
                    "upgrade.toml",
                    "[state_transition]\nbytecodes_supplier_addr = \"0x42a0AF13bd175F2aA6002Cc907F802fb9bAC32B6\"\n",
                ),
            ],
        );
        let args = SyncRuntimeContractsArgs {
            upgrade_output_toml: dir.join("upgrade.toml"),
            zkstack_config_dir: dir.clone(),
        };
        run(args).await.unwrap();
        for rel in [
            "configs/contracts.yaml",
            "chains/era/configs/contracts.yaml",
            "chains/gateway/configs/contracts.yaml",
        ] {
            let updated = std::fs::read_to_string(dir.join(rel)).unwrap();
            assert!(
                updated.contains("0x42a0AF13bd175F2aA6002Cc907F802fb9bAC32B6"),
                "{rel} not updated"
            );
            assert!(!updated.contains("0xOLD"), "{rel} still has stale value");
        }
    }

    #[tokio::test]
    async fn run_rejects_zero_address() {
        let dir = write_tmp_workspace(
            "run_zero",
            &[
                (
                    "configs/contracts.yaml",
                    "core_ecosystem_contracts:\n  l1_bytecodes_supplier_addr: 0xOLD\n",
                ),
                (
                    "upgrade.toml",
                    "[state_transition]\nbytecodes_supplier_addr = \"0x0000000000000000000000000000000000000000\"\n",
                ),
            ],
        );
        let args = SyncRuntimeContractsArgs {
            upgrade_output_toml: dir.join("upgrade.toml"),
            zkstack_config_dir: dir,
        };
        let err = run(args).await.unwrap_err();
        assert!(format!("{err:#}").contains("zero address"));
    }
}
