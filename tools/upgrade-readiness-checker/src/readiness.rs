//! Readiness checks against the chain's own L2 RPC.
//!
//! Only two standard eth_* methods are needed:
//!
//! 1. `eth_getTransactionReceipt` — does the chain's server have a receipt for
//!    the canonical upgrade-tx hash? If so, the server processed it in block N.
//! 2. `eth_getBlockByNumber("finalized", false)` — in zksync-os this resolves
//!    to `last_executed_block`, i.e. the highest L2 block whose batch has been
//!    executed on the settlement layer. Comparing `finalized >= N - 1` tells
//!    us whether the block immediately before the upgrade block is finalized.

use alloy::primitives::B256;
use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
struct JsonRpcResponse<T> {
    result: Option<T>,
    error: Option<JsonRpcError>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcError {
    code: i64,
    message: String,
}

/// Partial view of `eth_getTransactionReceipt`. `blockNumber` is alloy's standard
/// hex-string encoding.
#[derive(Debug, Deserialize)]
struct TxReceipt {
    #[serde(rename = "blockNumber")]
    block_number: String,
}

/// Partial view of `eth_getBlockByNumber`. Only the header number matters here.
#[derive(Debug, Deserialize)]
struct BlockHeader {
    number: String,
}

pub enum Readiness {
    /// No receipt for the upgrade tx yet — server hasn't included it.
    ServerNotProcessed,
    /// Server processed the tx in `upgrade_block`, but the preceding block is
    /// not yet finalized (its batch hasn't been executed on the settlement layer).
    NotFinalized {
        upgrade_block: u64,
        finalized_block: u64,
    },
    /// Block `upgrade_block - 1` is finalized — safe to finalize the upgrade on L1.
    Ready {
        upgrade_block: u64,
        finalized_block: u64,
    },
}

pub async fn check_readiness(l2_rpc_url: &str, upgrade_tx_hash: B256) -> Result<Readiness> {
    let client = reqwest::Client::new();

    let Some(receipt) = fetch_receipt(&client, l2_rpc_url, upgrade_tx_hash).await? else {
        return Ok(Readiness::ServerNotProcessed);
    };
    let upgrade_block = parse_hex_u64(&receipt.block_number)
        .context("parse receipt.blockNumber")?;
    if upgrade_block == 0 {
        // Genesis — nothing to wait for.
        return Ok(Readiness::ServerNotProcessed);
    }

    let finalized_block = fetch_finalized_block_number(&client, l2_rpc_url)
        .await
        .context("eth_getBlockByNumber(\"finalized\")")?
        .unwrap_or(0);

    if finalized_block >= upgrade_block - 1 {
        Ok(Readiness::Ready {
            upgrade_block,
            finalized_block,
        })
    } else {
        Ok(Readiness::NotFinalized {
            upgrade_block,
            finalized_block,
        })
    }
}

async fn fetch_receipt(
    client: &reqwest::Client,
    rpc: &str,
    hash: B256,
) -> Result<Option<TxReceipt>> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getTransactionReceipt",
        "params": [format!("0x{:x}", hash)]
    });
    rpc_call(client, rpc, body).await
}

async fn fetch_finalized_block_number(
    client: &reqwest::Client,
    rpc: &str,
) -> Result<Option<u64>> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getBlockByNumber",
        "params": ["finalized", false]
    });
    let header: Option<BlockHeader> = rpc_call(client, rpc, body).await?;
    header.map(|h| parse_hex_u64(&h.number)).transpose()
}

async fn rpc_call<T: for<'de> Deserialize<'de>>(
    client: &reqwest::Client,
    rpc: &str,
    body: Value,
) -> Result<Option<T>> {
    let resp: JsonRpcResponse<T> = client
        .post(rpc)
        .json(&body)
        .send()
        .await
        .context("RPC request failed")?
        .json()
        .await
        .context("RPC response not valid JSON")?;
    if let Some(err) = resp.error {
        anyhow::bail!("RPC error {}: {}", err.code, err.message);
    }
    Ok(resp.result)
}

fn parse_hex_u64(s: &str) -> Result<u64> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    u64::from_str_radix(s, 16).with_context(|| format!("invalid hex u64 '{s}'"))
}
