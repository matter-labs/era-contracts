use std::fs;
use std::path::PathBuf;
use std::str::FromStr;

use anyhow::Context;
use clap::Parser;
use ethers::middleware::Middleware;
use ethers::types::{Address, BlockNumber, Bytes, TransactionRequest, H256, U256};
use futures::future::try_join_all;
use serde_json::Value;

use ethers::providers::{Http, Provider};
use ethers::signers::Signer;

use crate::common::logger;

/// Execute a Gnosis Safe Transaction Builder JSON file.
///
/// Safe TX Builder JSON does not carry the broadcasting Safe address — in the
/// real product it is implicit from "the Safe currently loaded in the UI". For
/// our replay tooling, the broadcaster is derived from the supplied
/// `--private-key`: every tx in the batch is sent under that key's address.
///
/// Implementation note: we replay each tx natively via ethers (sign locally,
/// send via `eth_sendRawTransaction`, await a receipt) instead of shelling
/// out to forge. Forge involvement here was pure overhead — every bundle
/// paid ~1-2s of forge startup before the first tx hit the wire. Native
/// replay drops the per-bundle floor to ~200-500ms total.
#[derive(Debug, Clone, Parser)]
pub struct DevExecuteSafeArgs {
    /// Path to a Gnosis Safe Transaction Builder JSON file.
    #[clap(long)]
    pub safe_file: PathBuf,
    /// L1 RPC URL.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    /// Private key whose address is used as the broadcaster for every tx in
    /// the batch.
    #[clap(long)]
    pub private_key: String,
}

pub async fn run(args: DevExecuteSafeArgs) -> anyhow::Result<()> {
    logger::step(format!("Execute Safe file: {}", args.safe_file.display()));

    let content = fs::read_to_string(&args.safe_file)
        .with_context(|| format!("Failed to read Safe file: {}", args.safe_file.display()))?;
    let root: Value =
        serde_json::from_str(&content).context("Failed to parse Safe file as JSON")?;
    let safe_txs = root
        .get("transactions")
        .and_then(|t| t.as_array())
        .ok_or_else(|| anyhow::anyhow!("Safe file missing or invalid `.transactions` array"))?;

    let pk_h256 = H256::from_str(&args.private_key)
        .context("invalid --private-key (expected 0x-prefixed hex)")?;
    let wallet = ethers::signers::LocalWallet::from_bytes(pk_h256.as_bytes())
        .context("invalid --private-key (failed to construct signer)")?;
    let from = ethers::signers::Signer::address(&wallet);

    // Resolve chain id once so the signer can include it in the EIP-155
    // signature (anvil rejects legacy txs without chain id).
    //
    // Set Provider's polling interval to 5ms before wrapping in a signer.
    // Default is 7s (tuned for mainnet block time); this is the primary
    // tail-latency knob on anvil's instamine, where a tx is mined in under
    // a millisecond and the only wait is the poller waking up. 5ms gives
    // an expected ~2.5ms wait per bundle and keeps per-bundle cost under
    // ~20ms end-to-end on localhost.
    let provider = Provider::<Http>::try_from(args.l1_rpc_url.as_str())
        .context("connect L1 provider")?
        .interval(std::time::Duration::from_millis(5));
    let chain_id = provider
        .get_chainid()
        .await
        .context("eth_chainId")?
        .as_u64();
    let client =
        ethers::middleware::SignerMiddleware::new(provider, wallet.with_chain_id(chain_id));

    logger::info(format!(
        "Replaying {} tx(s) under broadcaster {:#x}",
        safe_txs.len(),
        from,
    ));

    // Fetch starting nonce once. Assigning nonces locally lets us submit all
    // txs in the bundle concurrently — otherwise ethers would serialize on
    // `eth_getTransactionCount(pending)` inside each `send_transaction`, and
    // each `pending.await` would block the next submit. Anvil queues
    // same-account txs by nonce and mines them in order.
    let base_nonce = client
        .get_transaction_count(from, Some(BlockNumber::Pending.into()))
        .await
        .context("eth_getTransactionCount(pending)")?;

    // Parse + sign + submit all txs concurrently.
    let pending = try_join_all(safe_txs.iter().enumerate().map(|(idx, tx)| {
        let client = &client;
        async move {
            let to: Address = tx
                .get("to")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("Safe tx #{idx} missing `to`"))?
                .parse()
                .with_context(|| format!("Safe tx #{idx} `to` is not a valid address"))?;
            let data_hex = tx
                .get("data")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("Safe tx #{idx} missing `data`"))?;
            let data = Bytes::from(
                ethers::utils::hex::decode(data_hex.trim_start_matches("0x"))
                    .with_context(|| format!("Safe tx #{idx} `data` is not valid hex"))?,
            );
            let value_str = tx
                .get("value")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("Safe tx #{idx} missing `value`"))?;
            let value = parse_decimal_or_hex_u256(value_str)
                .with_context(|| format!("Safe tx #{idx} `value` is not a valid number"))?;

            // Legacy (type-0) tx, pre-set gas/gas_price/nonce so ethers skips
            // all three of `eth_estimateGas`, `eth_gasPrice`, and
            // `eth_getTransactionCount` — each of those would serialize the
            // bundle.
            let req = TransactionRequest::new()
                .from(from)
                .to(to)
                .data(data)
                .value(value)
                .chain_id(chain_id)
                .gas(30_000_000u64)
                .gas_price(1_000_000_000u64)
                .nonce(base_nonce + idx);

            client
                .send_transaction(req, None)
                .await
                .with_context(|| format!("eth_sendTransaction for Safe tx #{idx} (to {to:#x})"))
        }
    }))
    .await?;

    // Await all receipts concurrently.
    let tx_hashes: Vec<H256> = pending.iter().map(|p| p.tx_hash()).collect();
    let receipts = try_join_all(pending.into_iter().enumerate().map(|(idx, pending)| {
        let tx_hash = tx_hashes[idx];
        async move {
            pending
                .await
                .with_context(|| format!("await receipt for Safe tx #{idx} (hash {tx_hash:#x})"))?
                .ok_or_else(|| anyhow::anyhow!("no receipt for Safe tx #{idx} (hash {tx_hash:#x})"))
        }
    }))
    .await?;

    for (idx, receipt) in receipts.iter().enumerate() {
        let status = receipt.status.unwrap_or_default();
        anyhow::ensure!(
            status == 1.into(),
            "Safe tx #{idx} (hash {:#x}) reverted (status=0)",
            tx_hashes[idx],
        );
    }

    logger::success("Safe file executed");
    Ok(())
}

/// Safe Transaction Builder JSON sets `value` either as a decimal string
/// (`"0"`, `"1000"`) or a hex string (`"0x0"`, `"0x10"`). Accept both.
fn parse_decimal_or_hex_u256(raw: &str) -> anyhow::Result<U256> {
    let trimmed = raw.trim();
    if let Some(hex) = trimmed.strip_prefix("0x") {
        if hex.is_empty() {
            return Ok(U256::zero());
        }
        U256::from_str_radix(hex, 16).with_context(|| format!("invalid hex u256 {trimmed:?}"))
    } else {
        U256::from_dec_str(trimmed).with_context(|| format!("invalid decimal u256 {trimmed:?}"))
    }
}
