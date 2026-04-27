use std::fs;
use std::path::PathBuf;
use std::str::FromStr;

use anyhow::Context;
use clap::Parser;
use ethers::middleware::Middleware;
use ethers::types::{Address, BlockNumber, Bytes, TransactionRequest, H256, U256};
use serde_json::Value;

use ethers::providers::{Http, Provider};
use ethers::signers::Signer;

use crate::common::logger;

/// Per-tx gas estimate buffer in basis points (12500 = 125% = 25% headroom).
const GAS_ESTIMATE_BUFFER_BPS: u64 = 12_500;
/// Maximum per-tx gas limit. Reth's elastic block gas limit converges to
/// ~30M on a quiet chain; we cap below that so a single tx can never equal
/// or exceed the block limit (which reth rejects with `gas limit too high`).
const PER_TX_GAS_LIMIT_CAP: u64 = 20_000_000;

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
/// paid ~1-2s of forge startup before the first tx hit the wire. Bundles
/// with N txs now run in N round-trips of (estimateGas, sendTx,
/// awaitReceipt) sequentially.
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
    // Override Provider's polling interval (default 7s, tuned for mainnet)
    // so per-tx receipt polling doesn't dominate bundle latency on anvil's
    // instamine or reth's sub-second block time.
    let provider = Provider::<Http>::try_from(args.l1_rpc_url.as_str())
        .context("connect L1 provider")?
        .interval(std::time::Duration::from_millis(50));
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

    // Fetch starting nonce once and assign nonces locally — avoids a
    // serialised `eth_getTransactionCount(pending)` round-trip per tx.
    let base_nonce = client
        .get_transaction_count(from, Some(BlockNumber::Pending.into()))
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
            ethers::utils::hex::decode(data_hex.trim_start_matches("0x"))
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
        // `GAS_ESTIMATE_BUFFER_BPS` headroom and bail if the result
        // exceeds `PER_TX_GAS_LIMIT_CAP` — silently shipping past the cap
        // would just OOG on-chain after a successful estimate.
        let estimate_req: ethers::types::transaction::eip2718::TypedTransaction =
            TransactionRequest::new()
                .from(from)
                .to(to)
                .data(data.clone())
                .value(value)
                .into();
        let estimated = client
            .estimate_gas(&estimate_req, None)
            .await
            .with_context(|| format!("eth_estimateGas for Safe tx #{idx} (to {to:#x})"))?;
        let buffered =
            estimated.saturating_mul(U256::from(GAS_ESTIMATE_BUFFER_BPS)) / U256::from(10_000);
        anyhow::ensure!(
            buffered <= U256::from(PER_TX_GAS_LIMIT_CAP),
            "Safe tx #{idx} (to {to:#x}) gas estimate {estimated} \
             ({buffered} buffered) exceeds PER_TX_GAS_LIMIT_CAP {PER_TX_GAS_LIMIT_CAP}; \
             refusing to submit since the cap would OOG on-chain"
        );

        let req = TransactionRequest::new()
            .from(from)
            .to(to)
            .data(data)
            .value(value)
            .chain_id(chain_id)
            .gas(buffered)
            .gas_price(1_000_000_000u64)
            .nonce(base_nonce + idx);

        let pending = client
            .send_transaction(req, None)
            .await
            .with_context(|| format!("eth_sendTransaction for Safe tx #{idx} (to {to:#x})"))?;
        let tx_hash = pending.tx_hash();
        let receipt = pending
            .await
            .with_context(|| format!("await receipt for Safe tx #{idx} (hash {tx_hash:#x})"))?
            .ok_or_else(|| anyhow::anyhow!("no receipt for Safe tx #{idx} (hash {tx_hash:#x})"))?;
        let status = receipt.status.unwrap_or_default();
        anyhow::ensure!(
            status == 1.into(),
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
    if let Some(hex) = trimmed.strip_prefix("0x") {
        if hex.is_empty() {
            return Ok(U256::zero());
        }
        U256::from_str_radix(hex, 16).with_context(|| format!("invalid hex u256 {trimmed:?}"))
    } else {
        U256::from_dec_str(trimmed).with_context(|| format!("invalid decimal u256 {trimmed:?}"))
    }
}
