//! Replaying a runbook's txs on an anvil fork, each from its sender, to record facts the page
//! can state: the fork block and its date, each sender's nonce, which senders are EOAs, and
//! that every tx succeeds in order.

use std::collections::BTreeSet;

use alloy::eips::BlockNumberOrTag;
use alloy::network::TransactionBuilder;
use alloy::providers::Provider;
use alloy::rpc::types::TransactionRequest;
use anyhow::Context;

use super::{CheckFacts, Runbook};
use crate::common::anvil::{evm_increase_time_and_mine, evm_revert, evm_snapshot, set_balance};
use crate::common::ethereum::get_provider;

/// Replay every tx of `runbook` on the anvil fork at `rpc_url` (with `--auto-impersonate`),
/// in order, each from its sender, and fail on the first revert. A tx's `time_increase`
/// advances the fork's clock before it is sent, as the page tells the simulator to (a stage
/// timer's `checkDeadline()` reverts otherwise). The fork's state is restored afterwards.
/// `fork_block` is the L1 block the fork was taken at; `replayed_after` says what the caller
/// already replayed on it (e.g. the deploy bundle), for the page.
pub async fn check_on_fork(
    rpc_url: &str,
    runbook: &Runbook,
    fork_block: u64,
    replayed_after: Option<&str>,
) -> anyhow::Result<CheckFacts> {
    let provider = get_provider(rpc_url)?;
    let block = provider
        .get_block_by_number(BlockNumberOrTag::Number(fork_block))
        .await
        .with_context(|| format!("eth_getBlockByNumber({fork_block})"))?
        .ok_or_else(|| anyhow::anyhow!("fork block {fork_block} not found"))?;
    let timestamp = i64::try_from(block.header.timestamp).context("block timestamp")?;
    let date = chrono::DateTime::from_timestamp(timestamp, 0)
        .ok_or_else(|| anyhow::anyhow!("block timestamp {timestamp} out of range"))?
        .format("%Y-%m-%d")
        .to_string();

    let mut nonces = Vec::new();
    let mut eoa_senders = BTreeSet::new();
    for tx in &runbook.txs {
        if nonces.iter().any(|(sender, _)| *sender == tx.from) {
            continue;
        }
        let nonce = provider
            .get_transaction_count(tx.from)
            .await
            .with_context(|| format!("eth_getTransactionCount({:#x})", tx.from))?;
        let code = provider
            .get_code_at(tx.from)
            .await
            .with_context(|| format!("eth_getCode({:#x})", tx.from))?;
        if code.is_empty() {
            eoa_senders.insert(tx.from);
        }
        nonces.push((tx.from, nonce));
    }

    let snapshot = evm_snapshot(rpc_url).await?;
    let replay = replay(rpc_url, runbook).await;
    evm_revert(rpc_url, &snapshot).await?;
    replay?;

    Ok(CheckFacts {
        fork_block,
        date,
        nonces,
        eoa_senders,
        replayed_after: replayed_after.map(str::to_string),
    })
}

async fn replay(rpc_url: &str, runbook: &Runbook) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    let senders: BTreeSet<_> = runbook.txs.iter().map(|tx| tx.from).collect();
    for sender in senders {
        set_balance(rpc_url, sender).await?;
    }
    for (i, tx) in runbook.txs.iter().enumerate() {
        let what = format!("runbook tx {} ({}) from {:#x}", i + 1, tx.label, tx.from);
        if let Some(seconds) = tx.time_increase {
            evm_increase_time_and_mine(rpc_url, seconds).await?;
        }
        let request = TransactionRequest::default()
            .with_from(tx.from)
            .with_to(tx.to)
            .with_value(tx.value)
            .with_input(tx.data.clone());
        let receipt = provider
            .send_transaction(request)
            .await
            .with_context(|| format!("{what} was rejected"))?
            .get_receipt()
            .await
            .with_context(|| format!("{what}: no receipt"))?;
        anyhow::ensure!(receipt.status(), "{what} reverted on the fork");
    }
    Ok(())
}
