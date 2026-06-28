use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::client::ClientBuilder;
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
use alloy::transports::layers::RetryBackoffLayer;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::common::ethereum::get_provider;
use crate::common::{logger, PrivateKey};

/// One replayed Safe tx as it lands on L1, persisted to `--out` so the
/// PUVT (`ecosystem verify-upgrade`) can later reconstruct CREATE2 / TUPP
/// deployments from the prepare bundles. The fields mirror the legacy
/// `UpgradeOutput.transactions` shape but with the raw input data alongside
/// each hash, so verifier-side parsing doesn't need an extra
/// `eth_getTransactionByHash` round trip.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutedTx {
    pub tx_hash: String,
    pub to: String,
    pub data: String,
    pub value: String,
    pub status: u64,
}

/// Top-level shape written to `--out`. Multiple `dev execute-safe`
/// invocations can append by passing the same path; they are concatenated
/// in execution order so verifier-side replay matches the on-chain order.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExecutedBundle {
    pub transactions: Vec<ExecutedTx>,
}

/// Per-tx gas estimate buffer in basis points (12500 = 125% = 25% headroom).
const GAS_ESTIMATE_BUFFER_BPS: u64 = 12_500;
/// Maximum per-tx gas limit. Reth's elastic block gas limit converges to
/// ~30M on a quiet chain; we cap below that so a single tx can never equal
/// or exceed the block limit (which reth rejects with `gas limit too high`).
const PER_TX_GAS_LIMIT_CAP: u64 = 20_000_000;
/// Floor gas price (1 gwei). Used when the node returns `eth_gasPrice` below
/// it (anvil/reth on a quiet local chain reports near-zero).
const GAS_PRICE_FLOOR_WEI: u128 = 1_000_000_000;
/// Multiplier (in basis points) applied to live `eth_gasPrice` so our txs
/// outbid the base-fee floor on a busy public chain (Sepolia / mainnet). 300%
/// gives us ~3x headroom over chain median which is what gets txs included
/// within 1-2 blocks instead of hanging in the mempool for 30+ minutes.
const GAS_PRICE_MULTIPLIER_BPS: u128 = 30_000;

/// Receipt polling interval. Alloy's default is tuned for public chains;
/// tighten it so per-tx receipt polling doesn't dominate bundle latency on
/// anvil's instamine or reth's sub-second block time.
const RECEIPT_POLL_INTERVAL_MS: u64 = 50;

/// Effective receipt-poll interval. 50ms is right for a dedicated node, but it
/// 429s public RPCs (e.g. broadcasting a 74-tx bundle to Sepolia over a shared
/// endpoint). Allow an env override so a real-L1 deploy over a rate-limited RPC
/// can back off without a dedicated node. Falls back to the const.
fn receipt_poll_interval_ms() -> u64 {
    std::env::var("EXECUTE_SAFE_POLL_INTERVAL_MS")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|&v| v > 0)
        .unwrap_or(RECEIPT_POLL_INTERVAL_MS)
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|&v| v > 0)
        .unwrap_or(default)
}

/// Build the rate-limit retry/backoff layer for the signer-path provider.
/// Defaults are effectively unthrottled (preserving behaviour on a dedicated
/// node) but retry on 429, so a transient rate limit no longer aborts a whole
/// bundle. For a shared/public RPC, lower `EXECUTE_SAFE_CUPS` (compute units
/// per second; ~20 CU per request → req/s ≈ CUPS/20) to throttle proactively.
///   EXECUTE_SAFE_RETRY_MAX        max 429 retries per request (default 20)
///   EXECUTE_SAFE_RETRY_BACKOFF_MS initial backoff (default 1000)
///   EXECUTE_SAFE_CUPS             compute-units/s budget (default 100000)
fn retry_layer() -> RetryBackoffLayer {
    RetryBackoffLayer::new(
        env_u64("EXECUTE_SAFE_RETRY_MAX", 20) as u32,
        env_u64("EXECUTE_SAFE_RETRY_BACKOFF_MS", 1000),
        env_u64("EXECUTE_SAFE_CUPS", 100_000),
    )
}

/// Returns a legacy `gasPrice` that's high enough to land within ~1-2 blocks
/// on busy public chains, but never below `GAS_PRICE_FLOOR_WEI` so local
/// chains (anvil/reth at 0 base fee) still get a non-zero price. We use
/// legacy (type-0) txs throughout this binary so an EIP-1559 split isn't
/// needed.
async fn resolve_gas_price<P: Provider>(provider: &P) -> anyhow::Result<u128> {
    let live = provider
        .get_gas_price()
        .await
        .context("eth_gasPrice failed")?;
    let bumped = live.saturating_mul(GAS_PRICE_MULTIPLIER_BPS) / 10_000;
    Ok(std::cmp::max(bumped, GAS_PRICE_FLOOR_WEI))
}

/// Render a wei gas price as gwei for logging.
fn format_gwei(gas_price: u128) -> String {
    alloy::primitives::utils::format_units(gas_price, "gwei")
        .unwrap_or_else(|_| gas_price.to_string())
}

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

    /// Optional path to append the replayed transactions to as JSON. Use the
    /// same path across multiple bundles (the file is read on entry and
    /// rewritten on exit, so successful replays of multiple bundles
    /// accumulate in execution order). Consumed later by
    /// `ecosystem verify-upgrade --executed-bundles <path>` so the verifier
    /// can reconstruct CREATE2 / TUPP deployments from the prepare output.
    #[clap(long)]
    pub out: Option<PathBuf>,
}

pub async fn run(args: DevExecuteSafeArgs) -> anyhow::Result<()> {
    execute_one_bundle(
        &args.safe_file,
        &args.l1_rpc_url,
        args.private_key.expose(),
        args.out.as_deref(),
    )
    .await
}

/// Replay a single Safe bundle file under one signer. Despite the file
/// extension, this is **not** a Safe-UI flow: the file is a plain
/// `transactions[]` JSON (Safe Transaction Builder–compatible for the multisig
/// case), and we sign + submit each tx directly via `eth_sendRawTransaction`.
/// Used both by `dev execute-safe` (single bundle) and the multi-bundle
/// dispatcher in `ecosystem upgrade-broadcast`.
pub async fn execute_one_bundle(
    safe_file: &Path,
    l1_rpc_url: &str,
    private_key: &str,
    out_path: Option<&Path>,
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
    // Layer a rate-limit retry/backoff onto the RPC client so a 429 from a
    // shared/public RPC backs off and retries instead of aborting the bundle.
    // (Hung requests on a flaky public RPC are bounded by the caller wrapping
    // this command in a `timeout`, after which the idempotent resume loop
    // retries — see run-local-workflow.sh.)
    let rpc_client = ClientBuilder::default()
        .layer(retry_layer())
        .http(l1_rpc_url.parse().context("invalid L1 RPC URL")?);
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_client(rpc_client);
    provider
        .client()
        .set_poll_interval(std::time::Duration::from_millis(receipt_poll_interval_ms()));

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

    // Resolve gas price once for the whole bundle. We dispatch back-to-back
    // so a single snapshot is fine; if Sepolia gas spikes mid-bundle we'll
    // see slow blocks rather than dropped txs (still better than the old
    // hardcoded 1-gwei sub-base-fee behaviour).
    let gas_price = resolve_gas_price(&provider)
        .await
        .context("resolve gas price")?;
    logger::info(format!("Using gas price {} gwei", format_gwei(gas_price)));

    // Per-bundle tx log loaded from `--out`; we only flush additions after
    // the entire bundle succeeds so failed bundles do not pollute outputs.
    let mut executed: ExecutedBundle = match out_path {
        Some(path) if path.exists() => {
            let raw = fs::read_to_string(path).with_context(|| {
                format!(
                    "failed to read existing executed-bundle file {}",
                    path.display()
                )
            })?;
            serde_json::from_str(&raw).with_context(|| {
                format!(
                    "failed to parse existing executed-bundle file {}",
                    path.display()
                )
            })?
        }
        _ => ExecutedBundle::default(),
    };
    let mut bundle_executed: Vec<ExecutedTx> = Vec::new();
    let mut bundle_hashes: Vec<B256> = Vec::new();

    // Parse + sign + submit each tx sequentially, awaiting its receipt
    // before the next. Some bundle txs depend on contracts deployed by
    // earlier txs in the same bundle (e.g. an initializer call after a
    // CREATE2 deploy), so concurrent `eth_estimateGas` would estimate
    // against pre-bundle L1 state and revert on dependent txs. Sequential
    // await-on-receipt also means later txs' estimateGas sees the
    // side-effects of earlier ones, and a revert in tx N stops the loop
    // before any tx N+1 hits the wire.
    let mut skipped: usize = 0;
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
        let estimate_req = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_input(data.clone())
            .with_value(value);
        let gas_limit: u64 = match provider.estimate_gas(estimate_req).await {
            Ok(est) => {
                let buffered = est.saturating_mul(GAS_ESTIMATE_BUFFER_BPS) / 10_000;
                std::cmp::min(buffered, PER_TX_GAS_LIMIT_CAP)
            }
            Err(e) => {
                // Idempotent skip: if estimation fails and the tx targets the
                // CREATE2 factory, check whether the output address already has
                // code (= already deployed in a prior partial broadcast). If so,
                // skip this tx instead of aborting the whole bundle.
                if should_skip_idempotent(&provider, to, &data).await {
                    logger::info(format!(
                        "Skipping Safe tx #{idx} (to {to:#x}) — already deployed / idempotent"
                    ));
                    skipped += 1;
                    continue;
                }
                // Check revert data for known idempotent errors from prior
                // partial broadcasts:
                // - OperationExists (0x876e8b23): legacy Governance.scheduleTransparent
                // - AddressAlreadySet (0x0dfb42bf): setup call already executed
                // - OperationMustBePending (0xb926a6b0): legacy Gov executeInstant
                //   on an already-done operation
                // - EVMBytecodeAlreadyPublished (0x61733a89) /
                //   EraBytecodeAlreadyPublished (0x876e8b23): BytecodesSupplier
                //   re-publish of a hash already published in a prior partial
                //   broadcast (no-op; later txs don't depend on the re-publish).
                let err_str = format!("{e}");
                let known_idempotent = [
                    "876e8b23", // OperationExists / EraBytecodeAlreadyPublished
                    "0dfb42bf", // AddressAlreadySet
                    "b926a6b0", // OperationMustBePending
                    "61733a89", // EVMBytecodeAlreadyPublished
                ];
                if let Some(sig) = known_idempotent.iter().find(|s| err_str.contains(**s)) {
                    logger::info(format!(
                        "Skipping Safe tx #{idx} (to {to:#x}) — idempotent revert ({sig})"
                    ));
                    skipped += 1;
                    continue;
                }
                // For CREATE2 factory calls that aren't skippable (target has
                // no code yet), retry with a generous fixed gas limit. The
                // estimation can fail on large initcodes or when the node's
                // gas cap is too low for the estimate call.
                let to_hex = format!("{to:#x}").to_lowercase();
                const CREATE2_FALLBACK_GAS: u64 = 10_000_000;
                if to_hex.contains(CREATE2_FACTORY) {
                    logger::info(format!(
                        "eth_estimateGas failed for CREATE2 tx #{idx}, using fallback gas limit {CREATE2_FALLBACK_GAS}"
                    ));
                    CREATE2_FALLBACK_GAS
                } else {
                    return Err(e).with_context(|| {
                        format!("eth_estimateGas for Safe tx #{idx} (to {to:#x})")
                    });
                }
            }
        };

        let req = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_input(data)
            .with_value(value)
            .with_nonce(base_nonce + (idx - skipped) as u64)
            .with_gas_limit(gas_limit)
            .with_gas_price(gas_price);

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

        if out_path.is_some() {
            bundle_executed.push(ExecutedTx {
                tx_hash: format!("{tx_hash:#x}"),
                to: format!("{to:#x}"),
                data: format!("0x{}", alloy::hex::encode(receipt_input(tx)?)),
                value: format!("{value}"),
                status: u64::from(receipt.status()),
            });
            bundle_hashes.push(tx_hash);
        }
    }

    if let Some(path) = out_path {
        if !bundle_executed.is_empty() {
            executed.transactions.extend(bundle_executed);
            persist_executed_bundle(path, &executed)?;
            for tx_hash in bundle_hashes {
                append_transaction_hash(path, tx_hash)?;
            }
        }
    }

    logger::success("Safe file executed");
    Ok(())
}

/// Well-known deterministic deployment proxy (EIP-2470 style).
const CREATE2_FACTORY: &str = "4e59b44847b379578588920ca78fbf26c0b4956c";

/// Check whether a failed `eth_estimateGas` should be treated as an
/// idempotent skip rather than a hard error. Currently handles:
/// - CREATE2 factory calls where the output address already has code
///   (the contract was deployed in a prior partial broadcast).
/// - Any other tx whose target already has code and the call reverts
///   (likely an already-executed governance operation).
async fn should_skip_idempotent<P: Provider>(provider: &P, to: Address, data: &Bytes) -> bool {
    let to_hex = format!("{to:#x}").to_lowercase();
    // CREATE2 factory: calldata = salt(32) + initcode.
    // Compute the would-be CREATE2 address and check if it already has code.
    if to_hex.contains(CREATE2_FACTORY) && data.len() >= 32 {
        let salt: [u8; 32] = data[..32].try_into().unwrap_or([0u8; 32]);
        let initcode = &data[32..];
        let deployed_addr = to.create2(salt, keccak256(initcode));
        if let Ok(code) = provider.get_code_at(deployed_addr).await {
            if !code.is_empty() {
                return true;
            }
        }
    }
    false
}

fn receipt_input(tx: &Value) -> anyhow::Result<Vec<u8>> {
    let data_hex = tx
        .get("data")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Safe tx missing `data` while building executed bundle"))?;
    alloy::hex::decode(data_hex.trim_start_matches("0x"))
        .context("Safe tx `data` is not valid hex while building executed bundle")
}

fn persist_executed_bundle(path: &Path, bundle: &ExecutedBundle) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create executed-bundle output dir {}",
                    parent.display()
                )
            })?;
        }
    }
    let serialized =
        serde_json::to_string_pretty(bundle).context("failed to serialise executed bundle")?;
    fs::write(path, serialized)
        .with_context(|| format!("failed to write executed-bundle file {}", path.display()))?;
    Ok(())
}

fn append_transaction_hash(out_path: &Path, tx_hash: B256) -> anyhow::Result<()> {
    let Some(parent) = out_path.parent() else {
        return Ok(());
    };
    if parent.as_os_str().is_empty() {
        return Ok(());
    }

    fs::create_dir_all(parent).with_context(|| {
        format!(
            "failed to create transactions.txt output dir {}",
            parent.display()
        )
    })?;
    let path = parent.join("transactions.txt");
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("failed to open transaction hash log {}", path.display()))?;
    writeln!(file, "{tx_hash:#x}")
        .with_context(|| format!("failed to append transaction hash to {}", path.display()))?;
    Ok(())
}

/// Replay a Safe bundle file under an **anvil-impersonated** EOA. Matches
/// `execute_one_bundle` on the wire shape but skips local signing — txs are
/// dispatched via `eth_sendTransaction` with `from` set to `sender`. Anvil
/// started with `--auto-impersonate` (or after `anvil_impersonateAccount`)
/// accepts these without holding the EOA's key. Used for fork-rehearsal of
/// stage / mainnet bundles whose real signer keys aren't available locally.
pub async fn execute_one_bundle_unlocked(
    safe_file: &Path,
    l1_rpc_url: &str,
    sender: Address,
    out_path: Option<&Path>,
) -> anyhow::Result<()> {
    logger::step(format!(
        "Execute Safe file (unlocked): {}",
        safe_file.display()
    ));

    let content = fs::read_to_string(safe_file)
        .with_context(|| format!("Failed to read Safe file: {}", safe_file.display()))?;
    let root: Value =
        serde_json::from_str(&content).context("Failed to parse Safe file as JSON")?;
    let safe_txs = root
        .get("transactions")
        .and_then(|t| t.as_array())
        .ok_or_else(|| anyhow::anyhow!("Safe file missing or invalid `.transactions` array"))?;

    let provider = get_provider(l1_rpc_url).context("connect L1 provider")?;
    provider
        .client()
        .set_poll_interval(std::time::Duration::from_millis(receipt_poll_interval_ms()));
    let chain_id = provider.get_chain_id().await.context("eth_chainId")?;

    logger::info(format!(
        "Replaying {} tx(s) under impersonated broadcaster {:#x}",
        safe_txs.len(),
        sender,
    ));

    let base_nonce = provider
        .get_transaction_count(sender)
        .block_id(alloy::eips::BlockNumberOrTag::Pending.into())
        .await
        .context("eth_getTransactionCount(pending)")?;

    // In unlocked (anvil-impersonate) mode, use a fixed low gas price
    // instead of querying the node. Anvil's EIP-1559 base fee escalation
    // can push `eth_gasPrice` 200x+ above prepare-time levels, causing
    // MsgValueTooLow on priority deposit txs whose mintValue was baked
    // in during prepare with a much lower gas price.
    let gas_price = GAS_PRICE_FLOOR_WEI;
    logger::info(format!("Using gas price {} gwei", format_gwei(gas_price)));

    // Same accumulating-write shape as `execute_one_bundle`: load any
    // existing log so multiple bundles into the same `--out` path stack in
    // execution order. Flush only after full-bundle success.
    let mut executed: ExecutedBundle = match out_path {
        Some(path) if path.exists() => {
            let raw = fs::read_to_string(path).with_context(|| {
                format!(
                    "failed to read existing executed-bundle file {}",
                    path.display()
                )
            })?;
            serde_json::from_str(&raw).with_context(|| {
                format!(
                    "failed to parse existing executed-bundle file {}",
                    path.display()
                )
            })?
        }
        _ => ExecutedBundle::default(),
    };
    let mut bundle_executed: Vec<ExecutedTx> = Vec::new();
    let mut bundle_hashes: Vec<B256> = Vec::new();

    let mut skipped: usize = 0;
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

        let estimate_req = TransactionRequest::default()
            .with_from(sender)
            .with_to(to)
            .with_input(data.clone())
            .with_value(value);
        let gas_limit: u64 = match provider.estimate_gas(estimate_req).await {
            Ok(estimated) => {
                let buffered = estimated.saturating_mul(GAS_ESTIMATE_BUFFER_BPS) / 10_000;
                std::cmp::min(buffered, PER_TX_GAS_LIMIT_CAP)
            }
            Err(e) => {
                // Keep unlocked replay idempotent like the signed path:
                // skip already-deployed CREATE2 txs / known already-done ops.
                if should_skip_idempotent(&provider, to, &data).await {
                    logger::info(format!(
                        "Skipping Safe tx #{idx} (to {to:#x}) — already deployed / idempotent"
                    ));
                    skipped += 1;
                    continue;
                }
                let err_str = format!("{e}");
                let known_idempotent = [
                    "1a21feed", // OperationExists (current Governance)
                    "876e8b23", // OperationExists / EraBytecodeAlreadyPublished
                    "61733a89", // EVMBytecodeAlreadyPublished(bytes32)
                    "0dfb42bf", // AddressAlreadySet
                    "eda2fbb1", // OperationMustBePending (current Governance)
                    "b926a6b0", // OperationMustBePending
                ];
                if let Some(sig) = known_idempotent.iter().find(|s| err_str.contains(**s)) {
                    logger::info(format!(
                        "Skipping Safe tx #{idx} (to {to:#x}) — idempotent revert ({sig})"
                    ));
                    skipped += 1;
                    continue;
                }
                let to_hex = format!("{to:#x}").to_lowercase();
                const CREATE2_FALLBACK_GAS: u64 = 10_000_000;
                if to_hex.contains(CREATE2_FACTORY) {
                    logger::info(format!(
                        "eth_estimateGas failed for CREATE2 tx #{idx}, using fallback gas limit {CREATE2_FALLBACK_GAS}"
                    ));
                    CREATE2_FALLBACK_GAS
                } else {
                    return Err(e).with_context(|| {
                        format!("eth_estimateGas for Safe tx #{idx} (to {to:#x})")
                    });
                }
            }
        };

        let req = TransactionRequest::default()
            .with_from(sender)
            .with_to(to)
            .with_input(data)
            .with_value(value)
            .with_chain_id(chain_id)
            .with_nonce(base_nonce + (idx - skipped) as u64)
            .with_gas_limit(gas_limit)
            .with_gas_price(gas_price);

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

        if out_path.is_some() {
            bundle_executed.push(ExecutedTx {
                tx_hash: format!("{tx_hash:#x}"),
                to: format!("{to:#x}"),
                data: format!("0x{}", alloy::hex::encode(receipt_input(tx)?)),
                value: format!("{value}"),
                status: u64::from(receipt.status()),
            });
            bundle_hashes.push(tx_hash);
        }
    }

    if let Some(path) = out_path {
        if !bundle_executed.is_empty() {
            executed.transactions.extend(bundle_executed);
            persist_executed_bundle(path, &executed)?;
            for tx_hash in bundle_hashes {
                append_transaction_hash(path, tx_hash)?;
            }
        }
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
