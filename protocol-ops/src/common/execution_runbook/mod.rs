//! `EXECUTE.md`: the transactions whoever executes an upgrade sends by hand, as a page they can
//! open on GitHub and copy from, one tx at a time, into MetaMask.
//!
//! The runbook is rendered from the upgrade's executable transaction list, which stays the
//! source of truth. Three list formats are read:
//! - an **emergency-upgrade-board JSON** (`EmergencyStageUpgradeCalldata.s.sol`): `approveHash`
//!   on each approving member Safe, then `executeEmergencyUpgrade` on the board, all from the
//!   Safes' owner;
//! - a **Safe-bundle `manifest.json`** plus the Safe Transaction Builder files it lists, each
//!   sent by the bundle's `target`;
//! - a **transaction-simulator JSON array** (`description, network, from, to, value, data`).
//!
//! Output is deterministic: transactions in source order, one section per run of consecutive
//! txs from the same sender, no clock reads. The only facts that do not come from the list are
//! the ones a fork check measured ([`check::check_on_fork`]); without a check they are left out.
//! The Markdown is written already formatted the way prettier formats it.

mod check;
mod decode;
mod load;
mod render;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use alloy::primitives::{Address, Bytes, U256};
use anyhow::Context;

use crate::common::env_config::{EnvConfig, OwnableProxyKind};

pub use check::check_on_fork;
pub use load::{default_runbook_path, load, LoadOptions};
pub use render::render;

/// File name of the runbook, written next to the upgrade's outputs.
pub const RUNBOOK_FILE: &str = "EXECUTE.md";

/// A rendered-to-be runbook: the transactions plus everything the page says about them.
#[derive(Debug, Clone)]
pub struct Runbook {
    /// Heading, e.g. `v0.33.0 compiler upgrade: stage execution (Sepolia)`.
    pub title: String,
    /// How the page links its source: a path relative to the runbook's directory.
    pub source_link: String,
    /// The source lies in the runbook's own directory.
    pub source_in_same_dir: bool,
    pub chain_id: u64,
    /// Environment name, when known (used as `the <env> owner`).
    pub env: Option<String>,
    pub source: SourceKind,
    pub txs: Vec<RunbookTx>,
    /// Names the inputs give to addresses. Never guessed: an address without an entry is shown
    /// as the bare address.
    pub names: BTreeMap<Address, String>,
    /// What a fork check measured; `None` when no check ran.
    pub facts: Option<CheckFacts>,
    /// Extra bullets supplied by the caller, rendered verbatim.
    pub notes: Vec<String>,
}

/// Which format the transactions came from; the page's wording depends on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceKind {
    /// `approveHash` on every approving member Safe, then `executeEmergencyUpgrade` on `board`.
    EmergencyBoard {
        board: Address,
        handler: Address,
        owner: Address,
    },
    /// Safe Transaction Builder bundles; each tx carries its file.
    SafeBundles,
    /// A transaction-simulator scenario.
    Simulator,
}

/// One transaction, in execution order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunbookTx {
    pub label: String,
    pub from: Address,
    pub to: Address,
    pub value: U256,
    pub data: Bytes,
    /// The Safe Transaction Builder file the tx is in, as linked from the runbook.
    pub safe_file: Option<String>,
    /// Seconds the transaction simulator advances time before this tx.
    pub time_increase: Option<u64>,
}

/// The result of replaying every tx, in order, on a fork, each from its sender.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckFacts {
    /// The L1 block the fork was taken at.
    pub fork_block: u64,
    /// That block's date (UTC), `YYYY-MM-DD`.
    pub date: String,
    /// Each sender's nonce before its first tx, in order of first appearance.
    pub nonces: Vec<(Address, u64)>,
    /// Senders that had no code at the fork block.
    pub eoa_senders: BTreeSet<Address>,
    /// What had already been replayed on the fork before the txs, e.g. `the deploy bundle`.
    pub replayed_after: Option<String>,
}

/// Names the env's permanent values give: the bridgehub, each CTM by flavor, and the legacy
/// Governance and ChainAdmin contracts that own CTMs or proxy admins.
pub fn env_names(env_cfg: &EnvConfig) -> BTreeMap<Address, String> {
    let mut names = BTreeMap::new();
    names.insert(env_cfg.bridgehub(), "Bridgehub".to_string());
    for ctm in env_cfg.ctms() {
        let name = match ctm.is_zk_sync_os {
            Some(true) => "ZKsync OS CTM",
            Some(false) => "Era CTM",
            None => "CTM",
        };
        names.insert(ctm.proxy, name.to_string());
    }
    for proxy in env_cfg.ownable_proxies() {
        let name = match proxy.kind {
            OwnableProxyKind::LegacyGovernance => "legacy Governance",
            OwnableProxyKind::OzChainAdmin => "ChainAdmin",
        };
        names.insert(proxy.addr, name.to_string());
    }
    names
}

/// Render `runbook` and write it to `path`.
pub fn write(runbook: &Runbook, path: &Path) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    fs::write(path, render(runbook)).with_context(|| format!("write {}", path.display()))
}
