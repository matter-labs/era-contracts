//! Parse `ecosystem.yaml` — the canonical topology + deployer description
//! every ops-shape protocol-ops command accepts via `--ecosystem`.
//!
//! Schema (kept in sync with `integration_tests::l1_state::EcosystemConfig`):
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

    /// Resolve a chain's ID by name; fails loudly if the chain isn't listed.
    pub fn chain_id(&self, chain_name: &str) -> anyhow::Result<u64> {
        self.chains
            .get(chain_name)
            .copied()
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "chain {chain_name:?} not found in ecosystem.yaml (known: {:?})",
                    self.chains.keys().collect::<Vec<_>>()
                )
            })
    }
}

/// Shared arg for ecosystem-wide ops commands (no chain target): accepts
/// a path to ecosystem.yaml and loads it. Used by e.g. `ecosystem upgrade`.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct EcosystemArgs {
    /// Path to the ecosystem.yaml describing bridgehub + chain topology.
    #[clap(long, help_heading = "Topology")]
    pub ecosystem: PathBuf,
}

impl EcosystemArgs {
    pub fn resolve(&self) -> anyhow::Result<Ecosystem> {
        Ecosystem::load(&self.ecosystem)
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
