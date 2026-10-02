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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutedTx {
    pub tx_hash: String,
    pub to: String,
    pub data: String,
    pub value: String,
    pub status: u64,
    /// Signer that broadcast the tx (`{:#x}`). Absent in journals written
    /// before resume support; such entries are never skipped on resume.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// Safe bundle file name the tx came from (provenance; not used for matching).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle: Option<String>,
    /// Zero-based position of the tx in that bundle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
}

/// Top-level shape written to `--out`. Multiple `dev execute-safe`
/// invocations can append by passing the same path; they are concatenated
/// in execution order so verifier-side replay matches the on-chain order.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutedBundle {
    pub transactions: Vec<ExecutedTx>,
}

/// The receipt journal of one broadcast run, shared by every bundle the run
/// executes. Two jobs: append each confirmed receipt (persisted to `--out` as
/// it lands, so a later failure cannot erase it), and let a resume skip calls
/// a prior run already executed.
///
/// A resume matches a tx against the journal on the CALL — target, calldata,
/// value — not on where it sits in a bundle: a re-cut bundle (same deployer,
/// changed contracts) reorders and interleaves calls, while the calls that
/// already executed are byte-identical. The signer is checked too when the
/// entry records one; entries from journals written before that field existed
/// carry none, and for them the on-chain receipt's `from` is the check. Every
/// candidate is then confirmed on THIS chain (receipt with status 1, same
/// target, same sender), so a journal carried over from another chain, or a
/// re-orged receipt, never skips anything.
///
/// One `--out` journal spans every bundle of a run, and two bundles can carry
/// byte-identical calls. An entry therefore justifies at most one skip per
/// run, across bundles: a call is skipped only as many times as it actually
/// mined. Entries this run appends are never candidates.
pub struct ResumeJournal {
    path: Option<PathBuf>,
    bundle: ExecutedBundle,
    /// Entries loaded from disk, i.e. prior runs' receipts. Entries this run
    /// appends sit past this index.
    prior: usize,
    /// Prior entries already used to skip a tx this run.
    claimed: Vec<bool>,
}

impl ResumeJournal {
    /// Load the journal at `out_path` (missing file or `None` = empty; with
    /// `None` nothing is persisted).
    pub fn load(out_path: Option<&Path>) -> anyhow::Result<Self> {
        let bundle = load_executed_bundle(out_path)?;
        let prior = bundle.transactions.len();
        Ok(Self {
            path: out_path.map(Path::to_path_buf),
            bundle,
            prior,
            claimed: vec![false; prior],
        })
    }

    /// Every entry, prior and appended, in execution order.
    pub fn transactions(&self) -> &[ExecutedTx] {
        &self.bundle.transactions
    }

    /// Append one confirmed receipt; persisted immediately when the journal
    /// has a path (see `record_executed_tx`).
    fn record(&mut self, tx_hash: B256, tx: ExecutedTx) -> anyhow::Result<()> {
        match &self.path {
            Some(path) => record_executed_tx(path, &mut self.bundle, tx_hash, tx),
            None => {
                self.bundle.transactions.push(tx);
                Ok(())
            }
        }
    }

    /// A prior run's confirmed execution of exactly this call, if the chain
    /// agrees; claims the entry so it cannot justify a second skip.
    async fn find_prior_execution<P: Provider>(
        &mut self,
        provider: &P,
        from: Address,
        to: Address,
        data: &Bytes,
        value: U256,
    ) -> anyhow::Result<Option<B256>> {
        let mut start = 0;
        while let Some(i) = self.next_prior_match_from(start, from, to, data, value) {
            start = i + 1;
            let entry = &self.bundle.transactions[i];
            let hash: B256 = entry.tx_hash.parse().with_context(|| {
                format!(
                    "journal entry #{i} has an invalid tx hash {}",
                    entry.tx_hash
                )
            })?;
            let Some(receipt) = provider
                .get_transaction_receipt(hash)
                .await
                .context("eth_getTransactionReceipt")?
            else {
                continue;
            };
            if receipt.status() && receipt.to == Some(to) && receipt.from == from {
                self.claimed[i] = true;
                return Ok(Some(hash));
            }
        }
        Ok(None)
    }

    /// Index of the first prior, unclaimed entry at or after `start` that
    /// records a successful execution of this call (pure half of
    /// `find_prior_execution`; see `journal_entry_matches`).
    fn next_prior_match_from(
        &self,
        start: usize,
        from: Address,
        to: Address,
        data: &Bytes,
        value: U256,
    ) -> Option<usize> {
        (start..self.prior).find(|&i| {
            !self.claimed[i]
                && journal_entry_matches(&self.bundle.transactions[i], from, to, data, value)
        })
    }
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

/// Receipt of whichever of `hashes` has mined, if any. The sender broadcasts
/// several hashes per nonce (the original plus gas-bumped replacements), so
/// every "did our tx land?" question has to be asked about all of them.
async fn find_mined<P: Provider>(
    provider: &P,
    hashes: &[B256],
) -> anyhow::Result<Option<(B256, u64)>> {
    for hash in hashes {
        if let Some(receipt) = provider
            .get_transaction_receipt(*hash)
            .await
            .context("eth_getTransactionReceipt")?
        {
            return Ok(Some((*hash, u64::from(receipt.status()))));
        }
    }
    Ok(None)
}

/// Submit one tx and confirm it, robust to the two public-chain hazards a naive
/// send-and-await hits:
///
///  * **Stuck (underpriced) tx** — if no receipt lands within `STUCK_WAIT_MS`,
///    bump the legacy gas price (≥ +15%) and re-broadcast the SAME nonce (a
///    replacement), up to `max_gas_price_wei`, until it mines or `MAX_TX_WAIT_MS`.
///  * **Nonce takeover** — if the sender's on-chain nonce advances past ours
///    without any of OUR submissions landing (some other tx grabbed the nonce),
///    re-fetch the next free nonce and re-broadcast our calldata there. Every
///    hash sent for the nonce — the original and each gas-bumped replacement —
///    is checked first: a replacement can reach the builder after the original
///    was already included, and mistaking that for a takeover would re-send
///    the same call at a fresh nonce and execute it twice.
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
    // Every hash broadcast for the CURRENT nonce: the original plus each
    // gas-bumped replacement. Any one of them may be the one that mines.
    let mut submitted: Vec<B256> = Vec::new();

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
                submitted.push(h);
                logger::info(format!(
                    "  submitted {h:#x} (nonce {nonce}, {} gwei)",
                    format_gwei(gas_price)
                ));
            }
            Err(e) => {
                let es = e.to_string().to_lowercase();
                if es.contains("nonce too low") || es.contains("nonce_too_low") {
                    // Our nonce was consumed. If any of our own submissions for
                    // it actually landed, take that one; otherwise resubmit our
                    // calldata at the next free nonce.
                    if let Some(mined) = find_mined(provider, &submitted).await? {
                        return Ok(mined);
                    }
                    let old = nonce;
                    nonce = pending_nonce(provider, from).await?;
                    submitted.clear();
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
                    if submitted.is_empty() {
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

        let hash = *submitted
            .last()
            .expect("a hash is set once we reach the wait loop");

        // Wait up to STUCK_WAIT_MS for a receipt on any of our submissions for
        // this nonce (an earlier, lower-priced one can still be the one that
        // mines).
        let wait_start = std::time::Instant::now();
        loop {
            if let Some(mined) = find_mined(provider, &submitted).await? {
                return Ok(mined);
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
            // Our nonce is spent. One of our submissions (edge race), or
            // someone else's tx?
            if let Some(mined) = find_mined(provider, &submitted).await? {
                return Ok(mined);
            }
            let old = nonce;
            nonce = pending_nonce(provider, from).await?;
            submitted.clear();
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
    let mut journal = ResumeJournal::load(args.out.as_deref())?;
    execute_one_bundle(
        &args.safe_file,
        &args.l1_rpc_url,
        args.private_key.expose(),
        &mut journal,
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
    journal: &mut ResumeJournal,
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

        // Resume: a prior partial run may already have mined this exact call.
        // Skip it if the journal says so and the chain confirms it; re-sending
        // would at best waste a tx and at worst revert the whole bundle (e.g. a
        // deployer's `transferOwnership` after ownership already moved on).
        if let Some(hash) = journal
            .find_prior_execution(&provider, from, to, &data, value)
            .await?
        {
            logger::info(format!(
                "Skipping Safe tx #{idx} (to {to:#x}) — already mined in a prior run as {hash:#x}"
            ));
            continue;
        }

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
                // Reverts that mean the call already took effect in a prior
                // partial broadcast (see `idempotent_revert`).
                if let Some(reason) =
                    idempotent_revert(&provider, to, &data, &e.to_string()).await?
                {
                    logger::info(format!(
                        "Skipping Safe tx #{idx} (to {to:#x}) — idempotent revert ({reason})"
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

        journal.record(
            tx_hash,
            ExecutedTx {
                tx_hash: format!("{tx_hash:#x}"),
                to: format!("{to:#x}"),
                data: format!("0x{}", alloy::hex::encode(receipt_input(tx)?)),
                value: format!("{value}"),
                status,
                from: Some(format!("{from:#x}")),
                bundle: Some(bundle_name(safe_file)),
                index: Some(idx),
            },
        )?;
    }

    logger::success("Safe file executed");
    Ok(())
}

/// Name under which a Safe bundle file is journaled: its file name.
fn bundle_name(safe_file: &Path) -> String {
    safe_file
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| safe_file.display().to_string())
}

/// Whether a journal entry records a successful execution of exactly this call:
/// same target, calldata and value, status 1, and — when the entry recorded a
/// signer — the same signer. Compares parsed values, not strings, so the
/// journal's own spelling (`{:#x}` addresses, `0x` hex data, decimal value) and
/// the Safe file's agree. Pure; the on-chain confirmation lives in
/// `ResumeJournal::find_prior_execution`.
fn journal_entry_matches(
    entry: &ExecutedTx,
    from: Address,
    to: Address,
    data: &Bytes,
    value: U256,
) -> bool {
    if entry.status != 1 {
        return false;
    }
    match entry.from.as_deref().map(str::parse::<Address>) {
        None => {}
        Some(Ok(entry_from)) if entry_from == from => {}
        Some(_) => return false,
    }
    let Ok(entry_to) = entry.to.parse::<Address>() else {
        return false;
    };
    let Ok(entry_data) = alloy::hex::decode(entry.data.trim_start_matches("0x")) else {
        return false;
    };
    let Ok(entry_value) = parse_decimal_or_hex_u256(&entry.value) else {
        return false;
    };
    entry_to == to && entry_data.as_slice() == data.as_ref() && entry_value == value
}

// Error selectors (4 bytes, lowercase hex, as they appear in an
// `eth_estimateGas` revert) that mean the call already took effect in a prior
// partial broadcast, so replaying it is a no-op the bundle can skip.
/// `Governance.OperationExists()`: `scheduleTransparent` of an operation that is
/// already scheduled.
const OPERATION_EXISTS_SELECTOR: &str = "1a21feed";
/// `BytecodesSupplier.EraBytecodeAlreadyPublished(bytes32)`.
const ERA_BYTECODE_ALREADY_PUBLISHED_SELECTOR: &str = "876e8b23";
/// `BytecodesSupplier.EVMBytecodeAlreadyPublished(bytes32)`.
const EVM_BYTECODE_ALREADY_PUBLISHED_SELECTOR: &str = "61733a89";
/// `AddressAlreadySet(address)`: a one-shot setup call already executed.
const ADDRESS_ALREADY_SET_SELECTOR: &str = "0dfb42bf";
/// `Governance.OperationMustBePending()`. Ambiguous on its own — see
/// `idempotent_revert`.
const OPERATION_MUST_BE_PENDING_SELECTOR: &str = "eda2fbb1";
/// The pre-custom-errors Governance (mainnet's legacy instance) reverts with
/// this string where the current one raises `OperationMustBePending()`.
const OPERATION_MUST_BE_PENDING_LEGACY_MESSAGE: &str = "operation must be pending";

// `Governance.executeInstant(Operation)`, `execute(Operation)` and
// `hashOperation(Operation)` share one parameter encoding, so an operation's id
// is obtained by re-sending the call's own arguments under the `hashOperation`
// selector.
const GOVERNANCE_EXECUTE_INSTANT_SELECTOR: [u8; 4] = [0x95, 0x21, 0x8e, 0xcd];
const GOVERNANCE_EXECUTE_SELECTOR: [u8; 4] = [0x74, 0xda, 0x75, 0x6b];
const GOVERNANCE_HASH_OPERATION_SELECTOR: [u8; 4] = [0xc1, 0x26, 0xe8, 0x60];
const GOVERNANCE_IS_OPERATION_DONE_SELECTOR: [u8; 4] = [0x2a, 0xb0, 0xf5, 0x29];

/// What an `eth_estimateGas` revert string says about replaying the call.
#[derive(Debug, PartialEq, Eq)]
enum RevertClass {
    /// Already took effect; skip. Carries the matched error name for the log.
    AlreadyDone(&'static str),
    /// `OperationMustBePending`: skip only if Governance says the operation is
    /// `Done`.
    GovernanceOperationNotPending,
    /// Anything else: not ours to skip.
    Unknown,
}

/// Pure part of `idempotent_revert`: map a revert string to a `RevertClass`.
fn classify_revert(err: &str) -> RevertClass {
    let lower = err.to_lowercase();
    for (selector, name) in [
        (OPERATION_EXISTS_SELECTOR, "OperationExists"),
        (
            ERA_BYTECODE_ALREADY_PUBLISHED_SELECTOR,
            "EraBytecodeAlreadyPublished",
        ),
        (
            EVM_BYTECODE_ALREADY_PUBLISHED_SELECTOR,
            "EVMBytecodeAlreadyPublished",
        ),
        (ADDRESS_ALREADY_SET_SELECTOR, "AddressAlreadySet"),
    ] {
        if lower.contains(selector) {
            return RevertClass::AlreadyDone(name);
        }
    }
    if lower.contains(OPERATION_MUST_BE_PENDING_SELECTOR)
        || lower.contains(OPERATION_MUST_BE_PENDING_LEGACY_MESSAGE)
    {
        return RevertClass::GovernanceOperationNotPending;
    }
    RevertClass::Unknown
}

/// Whether an `eth_estimateGas` revert means the call already took effect in a
/// prior partial broadcast, so the tx can be skipped instead of aborting the
/// bundle. Returns what matched, for the log line.
///
/// `OperationMustBePending` is not enough by itself: `Governance.executeInstant`
/// / `execute` raise it for an operation that is Done (skipping is right) and
/// for one that was never scheduled or was cancelled (skipping would hide a
/// missing governance effect behind "Safe file executed"). For that revert the
/// operation's state is read from the Governance contract and only `Done`
/// skips.
async fn idempotent_revert<P: Provider>(
    provider: &P,
    to: Address,
    data: &Bytes,
    err: &str,
) -> anyhow::Result<Option<String>> {
    match classify_revert(err) {
        RevertClass::AlreadyDone(name) => Ok(Some(name.to_string())),
        RevertClass::GovernanceOperationNotPending => {
            if governance_operation_is_done(provider, to, data).await? {
                Ok(Some(
                    "OperationMustBePending; Governance reports the operation Done".to_string(),
                ))
            } else {
                Ok(None)
            }
        }
        RevertClass::Unknown => Ok(None),
    }
}

/// Whether the operation carried by an `executeInstant(Operation)` /
/// `execute(Operation)` call to `governance` is already `Done` there. False for
/// any other call shape.
async fn governance_operation_is_done<P: Provider>(
    provider: &P,
    governance: Address,
    data: &Bytes,
) -> anyhow::Result<bool> {
    let Some((selector, operation)) = data.split_first_chunk::<4>() else {
        return Ok(false);
    };
    if *selector != GOVERNANCE_EXECUTE_INSTANT_SELECTOR && *selector != GOVERNANCE_EXECUTE_SELECTOR
    {
        return Ok(false);
    }
    let mut hash_call = GOVERNANCE_HASH_OPERATION_SELECTOR.to_vec();
    hash_call.extend_from_slice(operation);
    let id = provider
        .call(
            TransactionRequest::default()
                .with_to(governance)
                .with_input(Bytes::from(hash_call)),
        )
        .await
        .context("Governance.hashOperation")?;
    anyhow::ensure!(
        id.len() == 32,
        "Governance.hashOperation returned {} bytes, expected 32",
        id.len()
    );
    let mut done_call = GOVERNANCE_IS_OPERATION_DONE_SELECTOR.to_vec();
    done_call.extend_from_slice(&id);
    let done = provider
        .call(
            TransactionRequest::default()
                .with_to(governance)
                .with_input(Bytes::from(done_call)),
        )
        .await
        .context("Governance.isOperationDone")?;
    Ok(done.len() == 32 && done[..31].iter().all(|b| *b == 0) && done[31] == 1)
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
        serde_json::to_string_pretty(bundle).context("failed to serialise executed bundle")? + "\n";
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
    journal: &mut ResumeJournal,
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

        // Resume: a prior partial run may already have mined this exact call.
        // Skip it if the journal says so and the chain confirms it; re-sending
        // would at best waste a tx and at worst revert the whole bundle (e.g. a
        // deployer's `transferOwnership` after ownership already moved on).
        if let Some(hash) = journal
            .find_prior_execution(&provider, sender, to, &data, value)
            .await?
        {
            logger::info(format!(
                "Skipping Safe tx #{idx} (to {to:#x}) — already mined in a prior run as {hash:#x}"
            ));
            skipped += 1;
            continue;
        }

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
                if let Some(reason) =
                    idempotent_revert(&provider, to, &data, &e.to_string()).await?
                {
                    logger::info(format!(
                        "Skipping Safe tx #{idx} (to {to:#x}) — idempotent revert ({reason})"
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

        journal.record(
            tx_hash,
            ExecutedTx {
                tx_hash: format!("{tx_hash:#x}"),
                to: format!("{to:#x}"),
                data: format!("0x{}", alloy::hex::encode(receipt_input(tx)?)),
                value: format!("{value}"),
                status: u64::from(receipt.status()),
                from: Some(format!("{sender:#x}")),
                bundle: Some(bundle_name(safe_file)),
                index: Some(idx),
            },
        )?;
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
    /// Reverts whose selector proves the effect already happened skip outright;
    /// `OperationMustBePending` (either spelling) is deferred to a Governance
    /// state check; everything else — including the `b926a6b0` value the old
    /// list carried, which is no known selector — is left alone.
    #[test]
    fn classify_revert_separates_done_from_ambiguous_and_unknown() {
        use super::RevertClass;
        let wrap = |sel: &str| {
            format!("server returned an error response: error code 3: execution reverted, data: \"0x{sel}00000000000000000000000000000000000000000000000000000000deadbeef\"")
        };
        assert_eq!(
            super::classify_revert(&wrap("1a21feed")),
            RevertClass::AlreadyDone("OperationExists")
        );
        assert_eq!(
            super::classify_revert(&wrap("876E8B23")),
            RevertClass::AlreadyDone("EraBytecodeAlreadyPublished")
        );
        assert_eq!(
            super::classify_revert(&wrap("61733a89")),
            RevertClass::AlreadyDone("EVMBytecodeAlreadyPublished")
        );
        assert_eq!(
            super::classify_revert(&wrap("0dfb42bf")),
            RevertClass::AlreadyDone("AddressAlreadySet")
        );
        assert_eq!(
            super::classify_revert(&wrap("eda2fbb1")),
            RevertClass::GovernanceOperationNotPending
        );
        assert_eq!(
            super::classify_revert("execution reverted: Operation must be pending"),
            RevertClass::GovernanceOperationNotPending
        );
        assert_eq!(
            super::classify_revert(&wrap("b926a6b0")),
            RevertClass::Unknown
        );
        assert_eq!(
            super::classify_revert("execution reverted: Ownable: caller is not the owner"),
            RevertClass::Unknown
        );
    }

    const JOURNAL_FROM: &str = "0xab75e283274247b43a1f220885850ebefa399b88";
    const JOURNAL_TO: &str = "0x7e7bc292a71b73cebe77633937ddad3dc1f80ed2";
    const JOURNAL_DATA: &str =
        "0xf2fde38b000000000000000000000000000000000000000000000000000000000000dead";

    /// A journal entry as the executor writes it (lowercase addresses, decimal
    /// value); `from` optional so legacy entries can be modelled.
    fn journal_entry(
        from: Option<&str>,
        to: &str,
        data: &str,
        value: &str,
        status: u64,
    ) -> super::ExecutedTx {
        super::ExecutedTx {
            tx_hash: format!("0x{}", "11".repeat(32)),
            to: to.to_string(),
            data: data.to_string(),
            value: value.to_string(),
            status,
            from: from.map(str::to_string),
            ..Default::default()
        }
    }

    fn full_entry() -> super::ExecutedTx {
        journal_entry(Some(JOURNAL_FROM), JOURNAL_TO, JOURNAL_DATA, "0", 1)
    }

    /// The call as the executor sees it: checksummed addresses, as a Safe TX
    /// Builder file spells them.
    fn safe_call() -> (
        alloy::primitives::Address,
        alloy::primitives::Address,
        alloy::primitives::Bytes,
    ) {
        let from = "0xaB75E283274247b43a1f220885850ebEFa399B88"
            .parse()
            .unwrap();
        let to = "0x7E7bc292A71B73CeBE77633937dDaD3dc1f80ED2"
            .parse()
            .unwrap();
        let data = alloy::primitives::Bytes::from(
            alloy::hex::decode(JOURNAL_DATA.trim_start_matches("0x")).unwrap(),
        );
        (from, to, data)
    }

    /// The journal spells addresses lowercase and the value in decimal; the
    /// Safe file may not. Matching is on parsed values. A legacy entry without
    /// a recorded signer matches on the call alone (the receipt's `from` is
    /// checked on chain instead).
    #[test]
    fn journal_entry_matches_ignores_spelling_and_accepts_legacy_entries() {
        let (from, to, data) = safe_call();
        let value = alloy::primitives::U256::ZERO;
        assert!(super::journal_entry_matches(
            &full_entry(),
            from,
            to,
            &data,
            value
        ));
        let mut hex_value = full_entry();
        hex_value.value = "0x0".to_string();
        assert!(super::journal_entry_matches(
            &hex_value, from, to, &data, value
        ));
        let legacy = journal_entry(None, JOURNAL_TO, JOURNAL_DATA, "0", 1);
        assert!(super::journal_entry_matches(
            &legacy, from, to, &data, value
        ));
    }

    /// A reverted entry, another signer, or a different target / calldata /
    /// value is not an execution of this call.
    #[test]
    fn journal_entry_matches_rejects_reverted_and_different_calls() {
        let (from, to, data) = safe_call();
        let value = alloy::primitives::U256::ZERO;
        let rejects = |label: &str, entry: super::ExecutedTx| {
            assert!(
                !super::journal_entry_matches(&entry, from, to, &data, value),
                "{label} must not match"
            );
        };
        let mut e = full_entry();
        e.status = 0;
        rejects("reverted", e);
        let mut e = full_entry();
        e.from = Some("0x0000000000000000000000000000000000000001".to_string());
        rejects("other signer", e);
        let mut e = full_entry();
        e.from = Some("not-an-address".to_string());
        rejects("garbage signer", e);
        let mut e = full_entry();
        e.to = "0x0000000000000000000000000000000000000001".to_string();
        rejects("other target", e);
        let mut e = full_entry();
        e.data = JOURNAL_DATA.replace("dead", "beef");
        rejects("other calldata", e);
        let mut e = full_entry();
        e.value = "1".to_string();
        rejects("other value", e);
    }

    /// One journal entry justifies one skip per run: two identical prior
    /// entries serve two identical calls (in any bundle) and no more, and
    /// entries appended by this run are never candidates.
    #[test]
    fn resume_journal_claims_each_prior_entry_once_and_ignores_new_entries() {
        let (from, to, data) = safe_call();
        let value = alloy::primitives::U256::ZERO;
        let mut journal = super::ResumeJournal {
            path: None,
            bundle: super::ExecutedBundle {
                transactions: vec![full_entry(), full_entry()],
            },
            prior: 2,
            claimed: vec![false, false],
        };
        assert_eq!(
            journal.next_prior_match_from(0, from, to, &data, value),
            Some(0)
        );
        journal.claimed[0] = true;
        assert_eq!(
            journal.next_prior_match_from(0, from, to, &data, value),
            Some(1)
        );
        journal.claimed[1] = true;
        assert_eq!(
            journal.next_prior_match_from(0, from, to, &data, value),
            None
        );
        // A receipt this run records is not a resume candidate.
        journal
            .record(alloy::primitives::B256::from([1_u8; 32]), full_entry())
            .unwrap();
        assert_eq!(journal.transactions().len(), 3);
        assert_eq!(
            journal.next_prior_match_from(0, from, to, &data, value),
            None
        );
        // Another signer's identical call finds nothing.
        let other: alloy::primitives::Address = "0x0000000000000000000000000000000000000001"
            .parse()
            .unwrap();
        journal.claimed = vec![false, false];
        assert_eq!(
            journal.next_prior_match_from(0, other, to, &data, value),
            None
        );
    }

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
            ..Default::default()
        };
        let second = ExecutedTx {
            tx_hash: format!("{second_hash:#x}"),
            to: "0x2222222222222222222222222222222222222222".to_string(),
            data: "0x02".to_string(),
            value: "0".to_string(),
            status: 1,
            ..Default::default()
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
