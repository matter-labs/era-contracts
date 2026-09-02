use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
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

/// Per-retry gas-price bump (basis points) when a tx is stuck. 11500 = +15%.
/// Must exceed 110% so geth/reth accept the replacement — they require a ≥10%
/// bump over the tx being replaced at the same nonce.
const GAS_BUMP_BPS: u128 = 11_500;
/// How long to wait for a receipt before treating a tx as stuck (then bump its
/// gas / check for a nonce takeover). ~7 mainnet blocks.
const STUCK_WAIT_MS: u128 = 90_000;
/// Poll interval while waiting for a receipt on a public chain.
const CONFIRM_POLL_MS: u64 = 4_000;
/// Overall per-tx deadline. Once gas hits the ceiling we keep re-broadcasting
/// at the ceiling until this elapses, then give up so a genuinely un-includable
/// tx can't hang a deploy forever.
const MAX_TX_WAIT_MS: u128 = 1_200_000; // 20 min
/// Default gas-price ceiling (gwei) for the bump loop, overridable per command
/// via `--max-gas-price-gwei`.
pub const DEFAULT_MAX_GAS_PRICE_GWEI: u128 = 500;

/// Receipt polling interval. Alloy's default is tuned for public chains;
/// tighten it so per-tx receipt polling doesn't dominate bundle latency on
/// anvil's instamine or reth's sub-second block time.
const RECEIPT_POLL_INTERVAL_MS: u64 = 50;

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

/// Next gas price for a stuck-tx retry, or `None` once at/above the ceiling.
/// Guarantees a strictly higher value (≥ `current + 1`) so the bump is never a
/// no-op due to integer rounding, and never exceeds `max`.
fn bump_gas(current: u128, max: u128) -> Option<u128> {
    if current >= max {
        return None;
    }
    let bumped = current.saturating_mul(GAS_BUMP_BPS) / 10_000;
    Some(std::cmp::min(std::cmp::max(bumped, current + 1), max))
}

/// Submit one tx and confirm it, robust to the two public-chain hazards a naive
/// send-and-await hits:
///
///  * **Stuck (underpriced) tx** — if no receipt lands within `STUCK_WAIT_MS`,
///    bump the legacy gas price (≥ +15%) and re-broadcast the SAME nonce (a
///    replacement), up to `max_gas_price_wei`, until it mines or `MAX_TX_WAIT_MS`.
///  * **Nonce takeover** — if the sender's on-chain nonce advances past ours
///    without our tx landing (some other tx grabbed the nonce), re-fetch the
///    next free nonce and re-broadcast our calldata there.
///
/// Callers award this before submitting the next tx, so the pending nonce is
/// always the next free one (strict one-at-a-time). Returns `(hash, status)` of
/// the submission that actually mined.
#[allow(clippy::too_many_arguments)]
async fn submit_and_confirm<P: Provider>(
    provider: &P,
    from: Address,
    to: Address,
    data: &Bytes,
    value: U256,
    gas_limit: u64,
    max_gas_price_wei: u128,
) -> anyhow::Result<(B256, u64)> {
    use alloy::eips::BlockNumberOrTag;

    async fn pending_nonce<P: Provider>(provider: &P, from: Address) -> anyhow::Result<u64> {
        provider
            .get_transaction_count(from)
            .block_id(BlockNumberOrTag::Pending.into())
            .await
            .context("eth_getTransactionCount(pending)")
    }

    let mut nonce = pending_nonce(provider, from).await?;
    let mut gas_price = std::cmp::min(resolve_gas_price(provider).await?, max_gas_price_wei);
    let started = std::time::Instant::now();
    let mut last_hash: Option<B256> = None;

    loop {
        let req = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_input(data.clone())
            .with_value(value)
            .with_nonce(nonce)
            .with_gas_limit(gas_limit)
            .with_gas_price(gas_price);

        match provider.send_transaction(req).await {
            Ok(p) => {
                let h = *p.tx_hash();
                last_hash = Some(h);
                logger::info(format!(
                    "  submitted {h:#x} (nonce {nonce}, {} gwei)",
                    format_gwei(gas_price)
                ));
            }
            Err(e) => {
                let es = e.to_string().to_lowercase();
                if es.contains("nonce too low") || es.contains("nonce_too_low") {
                    // Our nonce was consumed. If our own last submission actually
                    // landed, take it; otherwise resubmit our calldata at the
                    // next free nonce.
                    if let Some(h) = last_hash {
                        if let Some(r) = provider.get_transaction_receipt(h).await? {
                            return Ok((h, u64::from(r.status())));
                        }
                    }
                    let old = nonce;
                    nonce = pending_nonce(provider, from).await?;
                    logger::info(format!(
                        "  nonce {old} taken by another tx; resubmitting at nonce {nonce}"
                    ));
                    continue;
                }
                if es.contains("underpriced") || es.contains("already known") {
                    // Replacement needs a bigger bump, or the tx is already in
                    // the mempool. Bump for the next attempt; if we have an
                    // in-flight hash fall through to wait on it, else back off.
                    if let Some(g) = bump_gas(gas_price, max_gas_price_wei) {
                        gas_price = g;
                    }
                    if last_hash.is_none() {
                        if started.elapsed().as_millis() >= MAX_TX_WAIT_MS {
                            return Err(e).context("eth_sendTransaction (gave up after retries)");
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(CONFIRM_POLL_MS)).await;
                        continue;
                    }
                } else {
                    return Err(e).with_context(|| format!("eth_sendTransaction (to {to:#x})"));
                }
            }
        }

        let hash = last_hash.expect("a hash is set once we reach the wait loop");

        // Wait up to STUCK_WAIT_MS for a receipt.
        let wait_start = std::time::Instant::now();
        loop {
            if let Some(r) = provider
                .get_transaction_receipt(hash)
                .await
                .context("eth_getTransactionReceipt")?
            {
                return Ok((hash, u64::from(r.status())));
            }
            if wait_start.elapsed().as_millis() >= STUCK_WAIT_MS {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(CONFIRM_POLL_MS)).await;
        }

        if started.elapsed().as_millis() >= MAX_TX_WAIT_MS {
            anyhow::bail!(
                "tx to {to:#x} not mined within {}s (last {hash:#x}, nonce {nonce}, {} gwei)",
                MAX_TX_WAIT_MS / 1000,
                format_gwei(gas_price),
            );
        }

        // Stuck: did a different tx take our nonce, or are we just underpriced?
        let latest = provider
            .get_transaction_count(from)
            .block_id(BlockNumberOrTag::Latest.into())
            .await
            .context("eth_getTransactionCount(latest)")?;
        if latest > nonce {
            // Our nonce is spent. Our tx (edge race), or someone else's?
            if let Some(r) = provider.get_transaction_receipt(hash).await? {
                return Ok((hash, u64::from(r.status())));
            }
            let old = nonce;
            nonce = pending_nonce(provider, from).await?;
            logger::info(format!(
                "  nonce {old} taken by another tx; resubmitting at nonce {nonce}"
            ));
            continue;
        }
        // Still ours, still stuck → bump and replace (same nonce).
        match bump_gas(gas_price, max_gas_price_wei) {
            Some(g) => {
                logger::info(format!(
                    "  stuck; bumping gas {} -> {} gwei",
                    format_gwei(gas_price),
                    format_gwei(g)
                ));
                gas_price = g;
            }
            None => logger::info(format!(
                "  stuck at gas ceiling {} gwei; re-broadcasting and waiting",
                format_gwei(gas_price)
            )),
        }
    }
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
    /// same path across multiple bundles or retries. Each confirmed receipt is
    /// journaled immediately, so a later failure cannot erase the provenance
    /// of transactions that already mined. Consumed later by
    /// `ecosystem verify-upgrade --executed-bundles <path>` so the verifier
    /// can reconstruct CREATE2 / TUPP deployments from the prepare output.
    #[clap(long)]
    pub out: Option<PathBuf>,

    /// Gas-price ceiling (gwei) for the stuck-tx bump loop. A tx that doesn't
    /// mine promptly is re-broadcast at a higher gas price up to this cap.
    #[clap(long, default_value_t = DEFAULT_MAX_GAS_PRICE_GWEI)]
    pub max_gas_price_gwei: u128,
}

pub async fn run(args: DevExecuteSafeArgs) -> anyhow::Result<()> {
    execute_one_bundle(
        &args.safe_file,
        &args.l1_rpc_url,
        args.private_key.expose(),
        args.out.as_deref(),
        gwei_to_wei(args.max_gas_price_gwei),
    )
    .await
}

/// Convert a gwei ceiling to wei for the sender.
pub fn gwei_to_wei(gwei: u128) -> u128 {
    gwei.saturating_mul(1_000_000_000)
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
    max_gas_price_wei: u128,
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
    provider
        .client()
        .set_poll_interval(std::time::Duration::from_millis(RECEIPT_POLL_INTERVAL_MS));

    logger::info(format!(
        "Replaying {} tx(s) under broadcaster {:#x}",
        safe_txs.len(),
        from,
    ));

    logger::info(format!(
        "Gas-price ceiling {} gwei (bumps stuck txs up to this)",
        format_gwei(max_gas_price_wei)
    ));

    // Load the prior receipt journal so a retry in the same working directory
    // extends it instead of losing the provenance of an earlier partial run.
    let mut executed = load_executed_bundle(out_path)?;

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

        // Submit + confirm, re-fetching the nonce each time and bumping gas on
        // stuck txs (see `submit_and_confirm`). Strictly one at a time.
        let (tx_hash, status) = submit_and_confirm(
            &provider,
            from,
            to,
            &data,
            value,
            gas_limit,
            max_gas_price_wei,
        )
        .await
        .with_context(|| format!("Safe tx #{idx} (to {to:#x})"))?;
        anyhow::ensure!(
            status == 1,
            "Safe tx #{idx} (hash {tx_hash:#x}) reverted (status=0)",
        );

        if let Some(path) = out_path {
            record_executed_tx(
                path,
                &mut executed,
                tx_hash,
                ExecutedTx {
                    tx_hash: format!("{tx_hash:#x}"),
                    to: format!("{to:#x}"),
                    data: format!("0x{}", alloy::hex::encode(receipt_input(tx)?)),
                    value: format!("{value}"),
                    status,
                },
            )?;
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

fn load_executed_bundle(out_path: Option<&Path>) -> anyhow::Result<ExecutedBundle> {
    match out_path {
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
            })
        }
        _ => Ok(ExecutedBundle::default()),
    }
}

/// Journal one confirmed receipt immediately. `transactions.txt` is written
/// first because it is the PUVT's source of deployment provenance; the JSON is
/// then atomically replaced for the human/machine execution record. If a later
/// transaction in the same Safe bundle fails, this receipt survives the retry.
fn record_executed_tx(
    out_path: &Path,
    executed: &mut ExecutedBundle,
    tx_hash: B256,
    tx: ExecutedTx,
) -> anyhow::Result<()> {
    append_transaction_hash(out_path, tx_hash)?;
    executed.transactions.push(tx);
    persist_executed_bundle(out_path, executed)
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
    let temporary_path = path.with_extension("tmp");
    fs::write(&temporary_path, serialized).with_context(|| {
        format!(
            "failed to write temporary executed-bundle file {}",
            temporary_path.display()
        )
    })?;
    fs::rename(&temporary_path, path).with_context(|| {
        format!(
            "failed to replace executed-bundle file {} with {}",
            path.display(),
            temporary_path.display()
        )
    })?;
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
        .set_poll_interval(std::time::Duration::from_millis(RECEIPT_POLL_INTERVAL_MS));
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

    // Same append-on-each-receipt journal as the signed path.
    let mut executed = load_executed_bundle(out_path)?;

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

        if let Some(path) = out_path {
            record_executed_tx(
                path,
                &mut executed,
                tx_hash,
                ExecutedTx {
                    tx_hash: format!("{tx_hash:#x}"),
                    to: format!("{to:#x}"),
                    data: format!("0x{}", alloy::hex::encode(receipt_input(tx)?)),
                    value: format!("{value}"),
                    status: u64::from(receipt.status()),
                },
            )?;
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

#[cfg(test)]
mod tests {
    use std::fs;

    use alloy::primitives::B256;
    use tempfile::tempdir;

    use super::{
        bump_gas, gwei_to_wei, load_executed_bundle, record_executed_tx, ExecutedBundle,
        ExecutedTx, GAS_BUMP_BPS,
    };

    #[test]
    fn bump_gas_increases_by_at_least_the_replacement_threshold() {
        // +15% keeps replacements above geth's ≥10% requirement.
        let start = gwei_to_wei(10);
        let next = bump_gas(start, gwei_to_wei(500)).unwrap();
        assert_eq!(next, start * GAS_BUMP_BPS / 10_000);
        assert!(next >= start + start / 10, "bump must clear the +10% floor");
    }

    #[test]
    fn bump_gas_is_strictly_monotonic_even_for_tiny_values() {
        // Integer rounding must never yield a no-op bump.
        assert_eq!(bump_gas(1, 1_000), Some(2));
        assert_eq!(bump_gas(7, 1_000), Some(8));
    }

    #[test]
    fn bump_gas_caps_at_ceiling_then_stops() {
        let max = gwei_to_wei(100);
        // A bump that would overshoot is clamped to the ceiling...
        assert_eq!(bump_gas(gwei_to_wei(95), max), Some(max));
        // ...and once at/above the ceiling, no further bump is offered.
        assert_eq!(bump_gas(max, max), None);
        assert_eq!(bump_gas(max + 1, max), None);
    }

    #[test]
    fn confirmed_receipts_are_journaled_immediately_and_survive_retries() {
        let dir = tempdir().unwrap();
        let out = dir.path().join("executed.json");
        let first_hash = B256::from([1_u8; 32]);
        let second_hash = B256::from([2_u8; 32]);
        let first = ExecutedTx {
            tx_hash: format!("{first_hash:#x}"),
            to: "0x1111111111111111111111111111111111111111".to_string(),
            data: "0x01".to_string(),
            value: "0".to_string(),
            status: 1,
        };
        let second = ExecutedTx {
            tx_hash: format!("{second_hash:#x}"),
            to: "0x2222222222222222222222222222222222222222".to_string(),
            data: "0x02".to_string(),
            value: "0".to_string(),
            status: 1,
        };

        let mut first_run = ExecutedBundle::default();
        record_executed_tx(&out, &mut first_run, first_hash, first.clone()).unwrap();
        assert_eq!(
            load_executed_bundle(Some(&out)).unwrap().transactions,
            vec![first.clone()]
        );

        // Simulate a new process after the first bundle attempt failed.
        let mut retry = load_executed_bundle(Some(&out)).unwrap();
        record_executed_tx(&out, &mut retry, second_hash, second.clone()).unwrap();
        assert_eq!(
            load_executed_bundle(Some(&out)).unwrap().transactions,
            vec![first, second]
        );

        let hashes = fs::read_to_string(dir.path().join("transactions.txt")).unwrap();
        assert_eq!(
            hashes.lines().collect::<Vec<_>>(),
            vec![format!("{first_hash:#x}"), format!("{second_hash:#x}")]
        );
    }
}
