//! Topology args for protocol-ops subcommands.
//!
//! - `--bridgehub <addr>` for ecosystem-wide commands (or `--env <name>` to
//!   look the bridgehub up in `upgrade-envs/permanent-values/<env>.toml`).
//! - `--bridgehub <addr> --chain-id <u64>` for chain-targeted commands.
//!
//! When `--env` is passed, every other env-derived arg (CTM list, deployer,
//! era chain id, output dir, …) is auto-filled from the env's permanent-values
//! TOML + the v31 upgrade input TOML, unless an explicit CLI flag overrides.

use clap::Args;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::common::env_config::EnvConfig;

/// Shared arg for ecosystem-wide ops commands (no chain target).
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct EcosystemArgs {
    /// L1 Bridgehub proxy address. When omitted, `--env` must be set and the
    /// bridgehub is read from `upgrade-envs/permanent-values/<env>.toml`.
    #[clap(long, help_heading = "Topology")]
    pub bridgehub: Option<Address>,

    /// Per-env preset (`stage` / `testnet` / `mainnet` / `local`). Loads
    /// `upgrade-envs/permanent-values/<env>.toml` and supplies defaults for
    /// every env-derived arg (`--bridgehub`, `--ctm-config`, `--deployer-address`,
    /// `--out`, etc.). Explicit flags still override.
    #[clap(long, help_heading = "Topology")]
    pub env: Option<String>,
}

impl EcosystemArgs {
    /// Resolve the bridgehub address. Prefers explicit `--bridgehub`, falls
    /// back to the env preset.
    pub fn resolve(&self) -> anyhow::Result<Address> {
        if let Some(addr) = self.bridgehub {
            return Ok(addr);
        }
        let env = self.env.as_deref().ok_or_else(|| {
            anyhow::anyhow!("--bridgehub or --env must be supplied")
        })?;
        let cfg = EnvConfig::load(env)?;
        Ok(cfg.bridgehub())
    }

    /// Load the full env preset, if `--env` was passed.
    pub fn env_config(&self) -> anyhow::Result<Option<EnvConfig>> {
        match self.env.as_deref() {
            Some(env) => Ok(Some(EnvConfig::load(env)?)),
            None => Ok(None),
        }
    }
}

/// Shared args for chain-targeted ops commands.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct EcosystemChainArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub ecosystem: EcosystemArgs,

    /// Numeric chain id of the targeted ZK chain.
    #[clap(long, help_heading = "Topology")]
    pub chain_id: u64,
}

impl EcosystemChainArgs {
    pub fn resolve(&self) -> anyhow::Result<(Address, u64)> {
        Ok((self.ecosystem.resolve()?, self.chain_id))
    }
}
