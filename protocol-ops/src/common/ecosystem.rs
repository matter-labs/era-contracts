//! Topology args for protocol-ops subcommands. The previous `ecosystem.yaml`
//! file is gone — both shapes now take CLI flags directly:
//!
//! - `--bridgehub <addr>` for ecosystem-wide commands
//! - `--bridgehub <addr> --chain-id <u64>` for chain-targeted commands
//!
//! The chain set is no longer namespaced through a yaml file; callers pass
//! the raw chain id directly. Subcommands that need to enumerate chains
//! query `bridgehub.getAllZKChainChainIDs()` at runtime.

use clap::Args;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

/// Shared arg for ecosystem-wide ops commands (no chain target).
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct EcosystemArgs {
    /// L1 Bridgehub proxy address.
    #[clap(long, help_heading = "Topology")]
    pub bridgehub: Address,
}

impl EcosystemArgs {
    pub fn resolve(&self) -> anyhow::Result<Address> {
        Ok(self.bridgehub)
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
        Ok((self.ecosystem.bridgehub, self.chain_id))
    }
}
