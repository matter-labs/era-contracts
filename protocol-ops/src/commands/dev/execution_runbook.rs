use std::path::PathBuf;

use alloy::providers::Provider;
use anyhow::Context;
use clap::Parser;

use crate::common::env_config::EnvConfig;
use crate::common::ethereum::get_provider;
use crate::common::execution_runbook::{self, LoadOptions};
use crate::common::logger;

/// Anvil startup timeout for `--check-fork-url`.
const ANVIL_STARTUP_TIMEOUT_MS: u64 = 60_000;

/// Render `EXECUTE.md`, the copy-into-MetaMask runbook, from an upgrade's transaction list.
///
/// The input is an emergency-upgrade-board JSON, a Safe-bundle `manifest.json` (or its
/// directory), or a transaction-simulator JSON array. The runbook has one table per run of txs
/// from the same sender, decodes known calls, and links its source, which stays the source of
/// truth. With `--check-fork-url` every tx is replayed on a fork first, and what the replay
/// measured (fork block, sender nonces) goes into the page.
#[derive(Debug, Clone, Parser)]
pub struct DevExecutionRunbookArgs {
    /// The transaction list.
    #[clap(long)]
    pub input: PathBuf,
    /// Output path. Default: `EXECUTE.md` next to the input (next to the `sim-inputs/`
    /// directory for a manifest inside one).
    #[clap(long)]
    pub out: Option<PathBuf>,
    /// Environment (`permanent-values/<env>.toml`): the chain id, and names for the env's
    /// bridgehub, CTMs, legacy Governance and ChainAdmins.
    #[clap(long)]
    pub env: Option<String>,
    /// Upgrade name for the heading; inferred from an `upgrade-envs/<upgrade>/output/<env>/` path.
    #[clap(long)]
    pub upgrade: Option<String>,
    /// Chain id, if neither the list nor `--env` gives it.
    #[clap(long)]
    pub chain_id: Option<u64>,
    /// Heading override.
    #[clap(long)]
    pub title: Option<String>,
    /// An extra bullet, rendered as `Note: <text>`. Repeatable.
    #[clap(long = "note")]
    pub notes: Vec<String>,
    /// Simulator input only: drop txs whose tag starts with this prefix (e.g. `test_`). Repeatable.
    #[clap(long)]
    pub exclude_tag: Vec<String>,
    /// Replay every tx, in order and each from its sender, on an anvil fork of this L1 RPC
    /// before writing; nothing is sent to the RPC itself.
    #[clap(long)]
    pub check_fork_url: Option<String>,
    /// Block to fork for `--check-fork-url` (default: tip).
    #[clap(long, requires = "check_fork_url")]
    pub check_fork_block: Option<u64>,
}

pub async fn run(args: DevExecutionRunbookArgs) -> anyhow::Result<()> {
    let out = match &args.out {
        Some(out) => out.clone(),
        None => execution_runbook::default_runbook_path(&args.input)?,
    };
    let env_cfg = args.env.as_deref().map(EnvConfig::load).transpose()?;
    let env_chain_id = env_cfg.as_ref().and_then(EnvConfig::l1_chain_id);
    if let (Some(flag), Some(env)) = (args.chain_id, env_chain_id) {
        anyhow::ensure!(
            flag == env,
            "--chain-id {flag} disagrees with the env's l1_chain_id {env}"
        );
    }
    let options = LoadOptions {
        chain_id: args.chain_id.or(env_chain_id),
        upgrade: args.upgrade.clone(),
        env: args.env.clone(),
        title: args.title.clone(),
        names: env_cfg
            .as_ref()
            .map(execution_runbook::env_names)
            .unwrap_or_default(),
        exclude_tags: args.exclude_tag.clone(),
        notes: args.notes.clone(),
    };
    let mut runbook = execution_runbook::load(&args.input, &out, &options)?;

    if let Some(fork_url) = &args.check_fork_url {
        let mut anvil = alloy::node_bindings::Anvil::new()
            .fork(fork_url)
            .arg("--auto-impersonate")
            .arg("--disable-block-gas-limit")
            .timeout(ANVIL_STARTUP_TIMEOUT_MS);
        if let Some(block) = args.check_fork_block {
            anvil = anvil.fork_block_number(block);
        }
        let anvil = anvil
            .try_spawn()
            .context("spawn anvil for --check-fork-url")?;
        let rpc_url = anvil.endpoint();
        let fork_chain_id = get_provider(&rpc_url)?.get_chain_id().await?;
        anyhow::ensure!(
            fork_chain_id == runbook.chain_id,
            "--check-fork-url is chain {fork_chain_id}, the runbook is for chain {}",
            runbook.chain_id
        );
        let fork_block = match args.check_fork_block {
            Some(block) => block,
            None => get_provider(&rpc_url)?.get_block_number().await?,
        };
        logger::step(format!(
            "Replaying {} tx(s) on a fork at block {fork_block}",
            runbook.txs.len()
        ));
        runbook.facts =
            Some(execution_runbook::check_on_fork(&rpc_url, &runbook, fork_block, None).await?);
    }

    execution_runbook::write(&runbook, &out)?;
    logger::success(format!("Wrote {}", out.display()));
    Ok(())
}
