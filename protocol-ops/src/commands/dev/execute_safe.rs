use std::fs;
use std::path::{Path, PathBuf};

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::{Address, Bytes, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
use anyhow::Context;
use clap::Parser;
use serde_json::Value;

use crate::common::{logger, PrivateKey};

/// Per-tx gas estimate buffer in basis points (12500 = 125% = 25% headroom).
const GAS_ESTIMATE_BUFFER_BPS: u64 = 12_500;
/// Maximum per-tx gas limit. Reth's elastic block gas limit converges to
/// ~30M on a quiet chain; we cap below that so a single tx can never equal
/// or exceed the block limit (which reth rejects with `gas limit too high`).
const PER_TX_GAS_LIMIT_CAP: u64 = 20_000_000;

/// Execute a Gnosis Safe Transaction Builder JSON bundle: parse the
/// `transactions` array, sign each call locally under `--private-key`, and
/// submit via `eth_sendRawTransaction`.
///
/// Safe TX Builder JSON does not carry the broadcasting Safe address — in the
/// real product it is implicit from "the Safe currently loaded in the UI". For
/// our replay tooling, the broadcaster is derived from the supplied private
/// key (every tx in the batch is sent under that key's address).
///
/// Implementation note: we replay each tx natively via alloy (sign locally,
/// send via `eth_sendRawTransaction`, await a receipt) instead of shelling
/// out to forge. Forge involvement here was pure overhead — every bundle
/// paid ~1-2s of forge startup before the first tx hit the wire. Bundles
/// with N txs now run in N round-trips of (estimateGas, sendTx,
/// awaitReceipt) sequentially.
///
/// Multi-bundle outputs (emitted by prepare-shape commands as
/// `<dir>/manifest.json`) are dispatched by the *caller*: read the manifest's
/// `bundles[]`, look up the matching signer per `bundles[].target` from
/// whatever wallet source the caller has, and invoke this command once per
/// bundle.
#[derive(Debug, Clone, Parser)]
pub struct DevExecuteSafeArgs {
    /// Path to a Gnosis Safe Transaction Builder JSON file.
    #[clap(long)]
    pub safe_file: PathBuf,

    /// L1 RPC URL.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Private key whose address is used as the broadcaster for every tx in
    /// the bundle.
    #[clap(long)]
    pub private_key: PrivateKey,
}

pub async fn run(args: DevExecuteSafeArgs) -> anyhow::Result<()> {
    execute_one_bundle(&args.safe_file, &args.l1_rpc_url, args.private_key.expose()).await
}

/// Replay a single Safe bundle file under one signer.
pub async fn execute_one_bundle(
    safe_file: &Path,
    l1_rpc_url: &str,
    private_key: &str,
) -> anyhow::Result<()> {
    logger::step(format!("Execute Safe file: {}", safe_file.display()));

    let content = fs::read_to_string(safe_file)
        .with_context(|| format!("Failed to read Safe file: {}", safe_file.display()))?;
    let root: Value =
        serde_json::from_str(&content).context("Failed to parse Safe file as JSON")?;
    let safe_txs = root
        .get("transactions")
        .and_then(|t| t.as_array())
        .ok_or_else(|| anyhow::anyhow!("Safe file missing or invalid `.transactions` array"))?;

    let pk_hex = private_key.strip_prefix("0x").unwrap_or(private_key);
    let pk_bytes = alloy::hex::decode(pk_hex).context("invalid private key (expected hex)")?;
    let signer = PrivateKeySigner::from_slice(&pk_bytes)
        .context("invalid private key (failed to construct signer)")?;
    let from = signer.address();
    let wallet = EthereumWallet::from(signer);

    // Build provider with signer. ProviderBuilder::new() includes
    // recommended fillers (chain_id, gas, nonce); we override nonce and gas
    // manually per-tx below so those fillers are effectively a no-op for
    // the fields we set.
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(l1_rpc_url.parse().context("invalid L1 RPC URL")?);

    logger::info(format!(
        "Replaying {} tx(s) under broadcaster {:#x}",
        safe_txs.len(),
        from,
    ));

    // Fetch starting nonce once and assign nonces locally — avoids a
    // serialised `eth_getTransactionCount(pending)` round-trip per tx.
    // Must use Pending (not Latest) so in-flight txs from this address
    // don't cause nonce reuse if the signer already has pending mempool txs.
    let base_nonce = provider
        .get_transaction_count(from)
        .block_id(alloy::eips::BlockNumberOrTag::Pending.into())
        .await
        .context("eth_getTransactionCount(pending)")?;

    // Parse + sign + submit each tx sequentially, awaiting its receipt
    // before the next. Some bundle txs depend on contracts deployed by
    // earlier txs in the same bundle (e.g. an initializer call after a
    // CREATE2 deploy), so concurrent `eth_estimateGas` would estimate
    // against pre-bundle L1 state and revert on dependent txs. Sequential
    // await-on-receipt also means later txs' estimateGas sees the
    // side-effects of earlier ones, and a revert in tx N stops the loop
    // before any tx N+1 hits the wire.
    for (idx, tx) in safe_txs.iter().enumerate() {
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
            alloy::hex::decode(data_hex.trim_start_matches("0x"))
                .with_context(|| format!("Safe tx #{idx} `data` is not valid hex"))?,
        );
        let value_str = tx
            .get("value")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Safe tx #{idx} missing `value`"))?;
        let value = parse_decimal_or_hex_u256(value_str)
            .with_context(|| format!("Safe tx #{idx} `value` is not a valid number"))?;

        // Estimate gas per tx so we don't trip node-side `gas limit too
        // high` rejections (reth caps tx gas at the current elastic block
        // gas limit, ~30M on a quiet local chain). Apply
        // `GAS_ESTIMATE_BUFFER_BPS` headroom, clamped to
        // `PER_TX_GAS_LIMIT_CAP` to stay below the block gas limit.
        let estimated: u64 = provider
            .estimate_gas(
                TransactionRequest::default()
                    .with_from(from)
                    .with_to(to)
                    .with_input(data.clone())
                    .with_value(value),
            )
            .await
            .with_context(|| format!("eth_estimateGas for Safe tx #{idx} (to {to:#x})"))?;
        let buffered = estimated.saturating_mul(GAS_ESTIMATE_BUFFER_BPS) / 10_000;
        let gas_limit = std::cmp::min(buffered, PER_TX_GAS_LIMIT_CAP);

        let req = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_input(data)
            .with_value(value)
            .with_nonce(base_nonce + idx as u64)
            .with_gas_limit(gas_limit)
            .with_gas_price(1_000_000_000u128);

        let pending = provider
            .send_transaction(req)
            .await
            .with_context(|| format!("eth_sendTransaction for Safe tx #{idx} (to {to:#x})"))?;
        let tx_hash = *pending.tx_hash();
        let receipt = pending
            .get_receipt()
            .await
            .with_context(|| format!("await receipt for Safe tx #{idx} (hash {tx_hash:#x})"))?;
        anyhow::ensure!(
            receipt.status(),
            "Safe tx #{idx} (hash {tx_hash:#x}) reverted (status=0)",
        );
    }

    logger::success("Safe file executed");
    Ok(())
}

/// Safe Transaction Builder JSON sets `value` either as a decimal string
/// (`"0"`, `"1000"`) or a hex string (`"0x0"`, `"0x10"`). Accept both.
fn parse_decimal_or_hex_u256(raw: &str) -> anyhow::Result<U256> {
    let trimmed = raw.trim();
    if let Some(hex_str) = trimmed.strip_prefix("0x") {
        if hex_str.is_empty() {
            return Ok(U256::ZERO);
        }
        U256::from_str_radix(hex_str, 16).with_context(|| format!("invalid hex u256 {trimmed:?}"))
    } else {
        trimmed
            .parse::<U256>()
            .with_context(|| format!("invalid decimal u256 {trimmed:?}"))
    }
}
