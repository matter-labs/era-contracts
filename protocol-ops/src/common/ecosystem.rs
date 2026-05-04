//! Parse the topology + deployer description that every ops-shape
//! protocol-ops command needs.
//!
//! Two equivalent input formats are accepted:
//!
//! - `--ecosystem <path>`: the canonical neutral `ecosystem.yaml`. Used by
//!   any caller that already keeps an ecosystem snapshot in this format
//!   (e.g. matter-labs/zksync-os-integration-tests).
//! - `--zkstack-config-dir <dir>`: the root of a zkstack workspace
//!   (containing `configs/contracts.yaml`, `configs/wallets.yaml`, and
//!   `chains/<name>/configs/general.yaml`). Synthesizes the equivalent
//!   ecosystem snapshot in-process; saves zkstack-driven callers from
//!   hand-translating yaml fields.
//!
//! `ecosystem.yaml` schema (kept in sync with
//! `integration_tests::l1_state::EcosystemConfig`):
//!
//! ```yaml
//! bridgehub: 0x…
//! deployer: 0x…            # optional
//! chains:
//!   gateway: 506
//!   my_chain: 6565
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Args;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

/// Deserialization target for `ecosystem.yaml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Ecosystem {
    pub bridgehub: Address,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deployer: Option<Address>,
    pub chains: BTreeMap<String, u64>,
}

impl Ecosystem {
    /// Parse `ecosystem.yaml` at `path`.
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let body = std::fs::read_to_string(path)
            .with_context(|| format!("read ecosystem.yaml at {}", path.display()))?;
        serde_yaml::from_str(&body)
            .with_context(|| format!("parse ecosystem.yaml at {}", path.display()))
    }

    /// Synthesize an [`Ecosystem`] from a zkstack workspace directory.
    ///
    /// Reads `configs/contracts.yaml::core_ecosystem_contracts.bridgehub_proxy_addr`
    /// for the bridgehub, `configs/wallets.yaml::deployer.address` for the
    /// deployer EOA, and walks every `chains/<name>/configs/general.yaml`
    /// for `(chain-name → l2_chain_id)`. Assembles the same struct that
    /// `--ecosystem ecosystem.yaml` would have produced.
    ///
    /// The deployer is always `Some` on the zkstack path — zkstack
    /// workspaces always have a deployer.
    pub fn from_zkstack_dir(workspace: &Path) -> anyhow::Result<Self> {
        let bridgehub = read_yaml_address(
            &workspace.join("configs/contracts.yaml"),
            &["core_ecosystem_contracts", "bridgehub_proxy_addr"],
        )?;
        let deployer = read_yaml_address(
            &workspace.join("configs/wallets.yaml"),
            &["deployer", "address"],
        )?;
        let chains = read_zkstack_chains(&workspace.join("chains"))?;

        Ok(Self {
            bridgehub,
            deployer: Some(deployer),
            chains,
        })
    }

    /// Resolve a chain's ID by name; fails loudly if the chain isn't listed.
    pub fn chain_id(&self, chain_name: &str) -> anyhow::Result<u64> {
        self.chains.get(chain_name).copied().ok_or_else(|| {
            anyhow::anyhow!(
                "chain {chain_name:?} not found in ecosystem (known: {:?})",
                self.chains.keys().collect::<Vec<_>>()
            )
        })
    }
}

/// Read a YAML file and walk a dotted path to extract an `Address`.
fn read_yaml_address(path: &Path, dotted_path: &[&str]) -> anyhow::Result<Address> {
    let text = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let root: serde_yaml::Value =
        serde_yaml::from_str(&text).with_context(|| format!("parse {}", path.display()))?;
    let mut node = &root;
    for key in dotted_path {
        node = node.get(key).with_context(|| {
            format!("missing `{}` at {}", dotted_path.join("."), path.display())
        })?;
    }
    node.as_str().and_then(|s| s.parse().ok()).with_context(|| {
        format!(
            "value at `{}` in {} is not a hex address",
            dotted_path.join("."),
            path.display()
        )
    })
}

/// Walk every `chains/<name>/ZkStack.yaml` under `chains_dir` and collect
/// `(name → chain_id)`. We use `ZkStack.yaml` (the chain manifest) rather
/// than `configs/general.yaml`, because the latter only has `l2_chain_id`
/// nested inside specific config sections, while the manifest exposes it
/// as a top-level `chain_id` field.
///
/// Note: `DirEntry::file_type()` does not follow symlinks — symlinked
/// chain directories are silently skipped.
fn read_zkstack_chains(chains_dir: &Path) -> anyhow::Result<BTreeMap<String, u64>> {
    let mut chains = BTreeMap::new();
    let entries = std::fs::read_dir(chains_dir)
        .with_context(|| format!("read chains dir {}", chains_dir.display()))?;
    for entry in entries {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let manifest_path = entry.path().join("ZkStack.yaml");
        if !manifest_path.exists() {
            continue;
        }
        let manifest: serde_yaml::Value = serde_yaml::from_str(
            &std::fs::read_to_string(&manifest_path)
                .with_context(|| format!("read {}", manifest_path.display()))?,
        )
        .with_context(|| format!("parse {}", manifest_path.display()))?;
        let chain_id = manifest
            .get("chain_id")
            .and_then(|v| v.as_u64())
            .with_context(|| format!("missing chain_id in {}", manifest_path.display()))?;
        chains.insert(entry.file_name().to_string_lossy().into_owned(), chain_id);
    }
    anyhow::ensure!(
        !chains.is_empty(),
        "no chains found under {}",
        chains_dir.display()
    );
    Ok(chains)
}

/// Shared arg for ecosystem-wide ops commands (no chain target). Accepts
/// either `--ecosystem` (canonical ecosystem.yaml) or `--zkstack-config-dir`
/// (zkstack workspace root). Mutually exclusive; exactly one required.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct EcosystemArgs {
    /// Path to the ecosystem.yaml describing bridgehub + chain topology.
    #[clap(
        long,
        help_heading = "Topology",
        conflicts_with = "zkstack_config_dir",
        required_unless_present = "zkstack_config_dir"
    )]
    pub ecosystem: Option<PathBuf>,

    /// Path to the root of a zkstack workspace (containing `configs/` and
    /// `chains/`). The equivalent ecosystem snapshot is synthesized in
    /// memory; saves callers from hand-rolling an ecosystem.yaml.
    #[clap(
        long,
        help_heading = "Topology",
        conflicts_with = "ecosystem",
        required_unless_present = "ecosystem"
    )]
    pub zkstack_config_dir: Option<PathBuf>,
}

impl EcosystemArgs {
    pub fn resolve(&self) -> anyhow::Result<Ecosystem> {
        match (&self.ecosystem, &self.zkstack_config_dir) {
            (Some(p), None) => Ecosystem::load(p),
            (None, Some(d)) => Ecosystem::from_zkstack_dir(d),
            // clap's conflicts_with + required_unless_present forbid the
            // (Some, Some) and (None, None) cases.
            _ => anyhow::bail!("exactly one of --ecosystem or --zkstack-config-dir must be provided"),
        }
    }
}

/// Shared args for every ops-shape command that targets a chain in an
/// existing ecosystem. Flattened into each command's args struct. Init /
/// bootstrap commands don't use this — they produce the ecosystem.yaml
/// rather than consume it.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct EcosystemChainArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub ecosystem: EcosystemArgs,

    /// Chain name (key in ecosystem.yaml `chains:`).
    #[clap(long, help_heading = "Topology")]
    pub chain: String,
}

impl EcosystemChainArgs {
    /// Parse ecosystem.yaml and resolve the targeted chain's id.
    pub fn resolve(&self) -> anyhow::Result<(Ecosystem, u64)> {
        let eco = self.ecosystem.resolve()?;
        let chain_id = eco.chain_id(&self.chain)?;
        Ok((eco, chain_id))
    }

    /// Convenience for callers that only need `(bridgehub, chain_id)` —
    /// the most common shape across migrate / convert / chain admin flows.
    pub fn resolve_bridgehub(&self) -> anyhow::Result<(Address, u64)> {
        let (eco, chain_id) = self.resolve()?;
        Ok((eco.bridgehub, chain_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Write a tmp zkstack-shaped workspace under a unique dir, return its
    /// root. Mirrors the layout `from_zkstack_dir` expects: top-level
    /// `configs/{contracts,wallets}.yaml` plus `chains/<name>/ZkStack.yaml`.
    fn write_workspace(label: &str, files: &[(&str, &str)]) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("ecosystem_test_{}_{label}", std::process::id()));
        // Cleanup from previous test run if any.
        let _ = std::fs::remove_dir_all(&dir);
        for (rel, content) in files {
            let abs = dir.join(rel);
            std::fs::create_dir_all(abs.parent().unwrap()).unwrap();
            std::fs::write(&abs, content).unwrap();
        }
        dir
    }

    const CONTRACTS_YAML: &str = "
core_ecosystem_contracts:
  bridgehub_proxy_addr: 0x6c6fde934f342f0cc0d1ba22ef181cb2983a4db2
";
    const WALLETS_YAML: &str = "
deployer:
  address: 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049
  private_key: 0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110
governor:
  address: 0x8002cD98Cfb563492A6fB3E7C8243b7B9Ad4cc92
  private_key: 0x2d64990aa363e3d38ae3417950fd40801d75e3d3bd57b86d17fcc261a6c951c6
";

    #[test]
    fn from_zkstack_dir_single_chain() {
        let dir = write_workspace(
            "single_chain",
            &[
                ("configs/contracts.yaml", CONTRACTS_YAML),
                ("configs/wallets.yaml", WALLETS_YAML),
                (
                    "chains/era/ZkStack.yaml",
                    "id: 1\nname: era\nchain_id: 271\n",
                ),
            ],
        );
        let eco = Ecosystem::from_zkstack_dir(&dir).unwrap();
        assert_eq!(
            format!("{:#x}", eco.bridgehub),
            "0x6c6fde934f342f0cc0d1ba22ef181cb2983a4db2"
        );
        assert_eq!(
            format!("{:#x}", eco.deployer.unwrap()),
            "0x36615cf349d7f6344891b1e7ca7c72883f5dc049"
        );
        assert_eq!(eco.chains.len(), 1);
        assert_eq!(eco.chain_id("era").unwrap(), 271);
    }

    #[test]
    fn from_zkstack_dir_multi_chain_skips_dirs_without_manifest() {
        let dir = write_workspace(
            "multi_chain",
            &[
                ("configs/contracts.yaml", CONTRACTS_YAML),
                ("configs/wallets.yaml", WALLETS_YAML),
                ("chains/era/ZkStack.yaml", "chain_id: 271\n"),
                ("chains/gateway/ZkStack.yaml", "chain_id: 506\n"),
                // A subdir with no ZkStack.yaml — should be silently skipped
                // (e.g. `.git`, `node_modules`, half-removed checkouts).
                ("chains/scratchpad/README.md", "stray content\n"),
            ],
        );
        let eco = Ecosystem::from_zkstack_dir(&dir).unwrap();
        assert_eq!(eco.chains.len(), 2);
        assert_eq!(eco.chain_id("era").unwrap(), 271);
        assert_eq!(eco.chain_id("gateway").unwrap(), 506);
        assert!(eco.chain_id("scratchpad").is_err());
    }

    #[test]
    fn from_zkstack_dir_missing_bridgehub_errors() {
        let dir = write_workspace(
            "missing_bridgehub",
            &[
                // contracts.yaml present but missing the nested key
                ("configs/contracts.yaml", "core_ecosystem_contracts: {}\n"),
                ("configs/wallets.yaml", WALLETS_YAML),
                ("chains/era/ZkStack.yaml", "chain_id: 271\n"),
            ],
        );
        let err = Ecosystem::from_zkstack_dir(&dir).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("bridgehub_proxy_addr"),
            "expected error to mention missing bridgehub_proxy_addr; got: {msg}"
        );
    }

    #[test]
    fn from_zkstack_dir_no_chains_errors() {
        let dir = write_workspace(
            "no_chains",
            &[
                ("configs/contracts.yaml", CONTRACTS_YAML),
                ("configs/wallets.yaml", WALLETS_YAML),
                ("chains/.gitkeep", ""),
            ],
        );
        let err = Ecosystem::from_zkstack_dir(&dir).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("no chains found"),
            "expected 'no chains found' error; got: {msg}"
        );
    }
}
