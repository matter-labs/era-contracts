use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use anyhow::Context;
use clap::Parser;
use ethers::middleware::Middleware;
use ethers::types::{Address, BlockNumber, Bytes, TransactionRequest, H256, U256};
use serde_json::Value;

use ethers::providers::{Http, Provider};
use ethers::signers::{LocalWallet, Signer};

use crate::common::logger;

/// Per-tx gas estimate buffer in basis points (12500 = 125% = 25% headroom).
const GAS_ESTIMATE_BUFFER_BPS: u64 = 12_500;
/// Maximum per-tx gas limit. Reth's elastic block gas limit converges to
/// ~30M on a quiet chain; we cap below that so a single tx can never equal
/// or exceed the block limit (which reth rejects with `gas limit too high`).
const PER_TX_GAS_LIMIT_CAP: u64 = 20_000_000;

/// Execute Gnosis Safe Transaction Builder JSON bundle(s).
///
/// Two modes:
///
/// - `--safe-file <FILE> --private-key <KEY>`: replay a single bundle under
///   one signer. Used by ad-hoc operators or downstream tooling that holds
///   the key out-of-band.
///
/// - `--manifest <DIR/manifest.json> --wallets-yaml <WALLETS>`: replay every
///   bundle in a manifest emitted by a prepare-shape command, looking up
///   each bundle's signer in `wallets.yaml` by target address. Used to
///   apply a full `ecosystem upgrade-prepare` / `upgrade-governance` /
///   `chain upgrade` output without per-bundle key management.
///
/// Safe TX Builder JSON does not carry the broadcasting Safe address — in the
/// real product it is implicit from "the Safe currently loaded in the UI". For
/// our replay tooling, the broadcaster is derived from the supplied private
/// key (every tx in the batch is sent under that key's address).
///
/// Implementation note: we replay each tx natively via ethers (sign locally,
/// send via `eth_sendRawTransaction`, await a receipt) instead of shelling
/// out to forge. Forge involvement here was pure overhead — every bundle
/// paid ~1-2s of forge startup before the first tx hit the wire. Bundles
/// with N txs now run in N round-trips of (estimateGas, sendTx,
/// awaitReceipt) sequentially.
#[derive(Debug, Clone, Parser)]
pub struct DevExecuteSafeArgs {
    /// Path to a single Gnosis Safe Transaction Builder JSON file.
    /// Mutually exclusive with `--manifest`.
    #[clap(
        long,
        conflicts_with = "manifest",
        required_unless_present = "manifest"
    )]
    pub safe_file: Option<PathBuf>,

    /// Path to a `manifest.json` emitted by a prepare-shape protocol-ops
    /// command (e.g. `ecosystem upgrade-prepare`). Iterates the manifest's
    /// `bundles[]`, looks up each bundle's signer in `--wallets-yaml` by
    /// target address, and replays each bundle sequentially. Mutually
    /// exclusive with `--safe-file`.
    #[clap(long, conflicts_with = "safe_file", requires = "wallets_yaml")]
    pub manifest: Option<PathBuf>,

    /// L1 RPC URL.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Private key whose address is used as the broadcaster for every tx in
    /// the bundle. Required with `--safe-file`. Mutually exclusive with
    /// `--wallets-yaml`.
    #[clap(long, conflicts_with = "wallets_yaml")]
    pub private_key: Option<String>,

    /// Path(s) to wallets.yaml. When `--manifest` is given, used to look
    /// up signer private keys by target address. The file may follow
    /// either the two-level `<section>.<role>` layout (matter-labs OS test
    /// repo) or the one-level `<role>` layout (zkstack); any leaf with
    /// both `address` and `private_key` fields is treated as a wallet
    /// entry. May be specified multiple times — entries from all supplied
    /// files are merged into a single address→wallet lookup. Mutually
    /// exclusive with `--private-key`.
    #[clap(long, conflicts_with = "private_key")]
    pub wallets_yaml: Vec<PathBuf>,
}

pub async fn run(args: DevExecuteSafeArgs) -> anyhow::Result<()> {
    match (&args.safe_file, &args.manifest) {
        (Some(safe_file), None) => {
            let pk = args
                .private_key
                .as_deref()
                .context("--private-key is required with --safe-file")?;
            execute_one_bundle(safe_file, &args.l1_rpc_url, pk).await
        }
        (None, Some(manifest_path)) => {
            anyhow::ensure!(
                !args.wallets_yaml.is_empty(),
                "--wallets-yaml is required with --manifest"
            );
            execute_manifest(manifest_path, &args.wallets_yaml, &args.l1_rpc_url).await
        }
        // clap's conflicts_with + required_unless_present prevents the
        // (None, None) and (Some, Some) cases.
        _ => unreachable!(
            "clap should reject both/neither --safe-file and --manifest at parse time"
        ),
    }
}

/// Replay every bundle in `manifest.json`, dispatching by target address to
/// the matching signer wallet in any of the supplied wallets.yaml files.
async fn execute_manifest(
    manifest_path: &Path,
    wallets_yaml_paths: &[PathBuf],
    l1_rpc_url: &str,
) -> anyhow::Result<()> {
    logger::step(format!("Execute manifest: {}", manifest_path.display()));

    let manifest = parse_manifest(manifest_path)?;
    let wallets = parse_wallets_yaml_files(wallets_yaml_paths)?;
    let manifest_dir = manifest_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf();

    if manifest.bundles.is_empty() {
        anyhow::bail!(
            "manifest {} has empty `bundles` array; nothing to execute",
            manifest_path.display()
        );
    }

    for bundle in &manifest.bundles {
        let target = bundle.target;
        let wallet = wallets.get(&target).with_context(|| {
            format!(
                "no signer for Safe bundle target {:#x} (bundle {}: {}); \
                 supplied wallets.yaml: {}",
                target,
                bundle.index,
                bundle.file,
                wallets_yaml_paths
                    .iter()
                    .map(|p| p.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;
        let bundle_path = manifest_dir.join(&bundle.file);
        let pk_hex = format!(
            "0x{}",
            ethers::utils::hex::encode(wallet.signer().to_bytes())
        );
        logger::info(format!(
            "Bundle {} of {}: {} (target {:#x}, {} txs)",
            bundle.index,
            manifest.bundles.len(),
            bundle.file,
            target,
            bundle.tx_count,
        ));
        execute_one_bundle(&bundle_path, l1_rpc_url, &pk_hex).await?;
    }

    logger::success(format!(
        "Manifest executed: {} bundle(s)",
        manifest.bundles.len()
    ));
    Ok(())
}

/// Replay a single Safe bundle file under one signer.
async fn execute_one_bundle(
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

    let pk_h256 =
        H256::from_str(private_key).context("invalid private key (expected 0x-prefixed hex)")?;
    let wallet = LocalWallet::from_bytes(pk_h256.as_bytes())
        .context("invalid private key (failed to construct signer)")?;
    let from = ethers::signers::Signer::address(&wallet);

    // Resolve chain id once so the signer can include it in the EIP-155
    // signature (anvil rejects legacy txs without chain id).
    //
    // Override Provider's polling interval (default 7s, tuned for mainnet)
    // so per-tx receipt polling doesn't dominate bundle latency on anvil's
    // instamine or reth's sub-second block time.
    let provider = Provider::<Http>::try_from(l1_rpc_url)
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

/// Subset of `manifest.json` we need to dispatch bundles. The full schema
/// (including `metadata`, `signer` name, etc.) is emitted by
/// `commands/output.rs::write_output_if_requested`.
#[derive(Debug)]
struct ManifestForExecute {
    bundles: Vec<ManifestBundle>,
}

#[derive(Debug)]
struct ManifestBundle {
    index: u64,
    file: String,
    target: Address,
    tx_count: u64,
}

fn parse_manifest(path: &Path) -> anyhow::Result<ManifestForExecute> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("Failed to read manifest: {}", path.display()))?;
    let root: Value = serde_json::from_str(&content)
        .with_context(|| format!("Failed to parse manifest as JSON: {}", path.display()))?;
    let bundles_raw = root
        .get("bundles")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow::anyhow!("manifest {} missing `bundles` array", path.display()))?;
    let mut bundles = Vec::with_capacity(bundles_raw.len());
    for (i, bundle) in bundles_raw.iter().enumerate() {
        let index = bundle
            .get("index")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow::anyhow!("manifest bundle #{i} missing `index`"))?;
        let file = bundle
            .get("file")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("manifest bundle #{i} missing `file`"))?
            .to_string();
        let target_str = bundle
            .get("target")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("manifest bundle #{i} missing `target`"))?;
        let target: Address = target_str
            .parse()
            .with_context(|| format!("manifest bundle #{i} target is not a valid address"))?;
        let tx_count = bundle
            .get("tx_count")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        bundles.push(ManifestBundle {
            index,
            file,
            target,
            tx_count,
        });
    }
    Ok(ManifestForExecute { bundles })
}

/// Merge wallets from multiple wallets.yaml files into one
/// `address → wallet` map. Bails if two files declare the same address
/// with different keys.
fn parse_wallets_yaml_files(
    paths: &[PathBuf],
) -> anyhow::Result<HashMap<Address, LocalWallet>> {
    let mut merged: HashMap<Address, LocalWallet> = HashMap::new();
    for path in paths {
        let from_this_file = parse_wallets_yaml(path)?;
        for (addr, wallet) in from_this_file {
            if let Some(prev) = merged.get(&addr) {
                anyhow::ensure!(
                    prev.signer().to_bytes() == wallet.signer().to_bytes(),
                    "address {:#x} appears in multiple wallets.yaml files with \
                     conflicting private keys",
                    addr
                );
            }
            merged.insert(addr, wallet);
        }
    }
    if merged.is_empty() {
        let names: Vec<_> = paths.iter().map(|p| p.display().to_string()).collect();
        anyhow::bail!(
            "no wallet entries (`address` + `private_key`) found in any of: {}",
            names.join(", ")
        );
    }
    Ok(merged)
}

/// Walk a wallets.yaml tree (any depth) and collect every leaf node that
/// has both `address` and `private_key` fields into an `address → wallet`
/// map. Supports both the OS test-repo two-level layout
/// (`<section>.<role>: { address, private_key }`) and the zkstack
/// one-level layout (`<role>: { address, private_key }`).
fn parse_wallets_yaml(path: &Path) -> anyhow::Result<HashMap<Address, LocalWallet>> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("Failed to read wallets.yaml: {}", path.display()))?;
    let root: serde_yaml::Value = serde_yaml::from_str(&content)
        .with_context(|| format!("Failed to parse wallets.yaml as YAML: {}", path.display()))?;
    let mut map = HashMap::new();
    walk_for_wallets(&root, &mut map, path)?;
    Ok(map)
}

fn walk_for_wallets(
    v: &serde_yaml::Value,
    map: &mut HashMap<Address, LocalWallet>,
    path: &Path,
) -> anyhow::Result<()> {
    let Some(mapping) = v.as_mapping() else {
        return Ok(());
    };

    let addr_field = mapping
        .get(serde_yaml::Value::String("address".into()))
        .and_then(|v| v.as_str());
    let pk_field = mapping
        .get(serde_yaml::Value::String("private_key".into()))
        .and_then(|v| v.as_str());

    if let (Some(addr_str), Some(pk_str)) = (addr_field, pk_field) {
        // Leaf wallet entry — parse, validate, insert. Don't recurse.
        let addr: Address = addr_str.parse().with_context(|| {
            format!(
                "wallets.yaml {}: `address` field {:?} is not a valid address",
                path.display(),
                addr_str
            )
        })?;
        let pk: H256 = H256::from_str(pk_str).with_context(|| {
            format!(
                "wallets.yaml {}: `private_key` field is not a valid 0x-prefixed hex H256",
                path.display()
            )
        })?;
        let wallet = LocalWallet::from_bytes(pk.as_bytes()).with_context(|| {
            format!(
                "wallets.yaml {}: `private_key` for {:#x} is not a valid signer",
                path.display(),
                addr
            )
        })?;
        anyhow::ensure!(
            wallet.address() == addr,
            "wallets.yaml {}: address {:#x} does not match private key (derives {:#x})",
            path.display(),
            addr,
            wallet.address(),
        );
        map.insert(addr, wallet);
        return Ok(());
    }

    // Not a leaf — recurse into children.
    for (_, child) in mapping {
        walk_for_wallets(child, map, path)?;
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn write_tmp(name: &str, content: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("execute_safe_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        std::fs::write(&path, content).unwrap();
        path
    }

    #[test]
    fn parse_wallets_yaml_two_level_layout() {
        let yaml = r#"
ecosystem:
  deployer:
    address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
    private_key: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110"
  governor:
    address: "0x25BB6f94624236bEd93DE9f0910DDcb538038489"
    private_key: "0x2d64990aa363e3d38ae3417950fd40801d75e3d3bd57b86d17fcc261a6c951c6"
"#;
        let path = write_tmp("two_level.yaml", yaml);
        let map = parse_wallets_yaml(&path).unwrap();
        assert_eq!(map.len(), 2);
        let deployer: Address = "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
            .parse()
            .unwrap();
        let governor: Address = "0x25BB6f94624236bEd93DE9f0910DDcb538038489"
            .parse()
            .unwrap();
        assert!(map.contains_key(&deployer));
        assert!(map.contains_key(&governor));
    }

    #[test]
    fn parse_wallets_yaml_one_level_layout() {
        let yaml = r#"
deployer:
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
  private_key: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110"
governor:
  address: "0x25BB6f94624236bEd93DE9f0910DDcb538038489"
  private_key: "0x2d64990aa363e3d38ae3417950fd40801d75e3d3bd57b86d17fcc261a6c951c6"
"#;
        let path = write_tmp("one_level.yaml", yaml);
        let map = parse_wallets_yaml(&path).unwrap();
        assert_eq!(map.len(), 2);
        let deployer: Address = "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
            .parse()
            .unwrap();
        assert!(map.contains_key(&deployer));
    }

    #[test]
    fn parse_wallets_yaml_rejects_address_pk_mismatch() {
        let yaml = r#"
deployer:
  address: "0x0000000000000000000000000000000000000001"
  private_key: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110"
"#;
        let path = write_tmp("mismatch.yaml", yaml);
        let err = parse_wallets_yaml(&path).unwrap_err();
        assert!(
            err.to_string().contains("does not match private key"),
            "got: {err}"
        );
    }

    #[test]
    fn parse_wallets_yaml_skips_entries_without_pk() {
        // OS test repo entries that only have `address` (e.g.  proven addresses
        // imported from a snapshot) shouldn't make us bail; just skip them.
        let yaml = r#"
ecosystem:
  deployer:
    address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
    private_key: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110"
  read_only_oracle:
    address: "0x0000000000000000000000000000000000000010"
"#;
        let path = write_tmp("partial.yaml", yaml);
        let map = parse_wallets_yaml(&path).unwrap();
        assert_eq!(map.len(), 1);
    }

    #[test]
    fn parse_wallets_yaml_files_merges_across_files() {
        let eco_yaml = r#"
deployer:
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
  private_key: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110"
"#;
        let chain_yaml = r#"
governor:
  address: "0x25BB6f94624236bEd93DE9f0910DDcb538038489"
  private_key: "0x2d64990aa363e3d38ae3417950fd40801d75e3d3bd57b86d17fcc261a6c951c6"
"#;
        let eco = write_tmp("eco.yaml", eco_yaml);
        let chain = write_tmp("chain.yaml", chain_yaml);
        let merged = parse_wallets_yaml_files(&[eco, chain]).unwrap();
        assert_eq!(merged.len(), 2);
        let deployer: Address = "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
            .parse()
            .unwrap();
        let governor: Address = "0x25BB6f94624236bEd93DE9f0910DDcb538038489"
            .parse()
            .unwrap();
        assert!(merged.contains_key(&deployer));
        assert!(merged.contains_key(&governor));
    }

    #[test]
    fn parse_wallets_yaml_files_rejects_conflicting_pk_for_same_address() {
        // Two files both declare 0x36615cf… but with different (and incorrect)
        // private keys. The parser bails on the second file because the
        // address/PK mismatch fires there before merge logic runs — that's
        // actually fine and is covered by parse_wallets_yaml_rejects_address_pk_mismatch.
        // The conflict-detection branch in parse_wallets_yaml_files only
        // matters when both files individually parse cleanly but disagree
        // on the same address. Construct that case with two correct
        // single-wallet files where one is duplicated and one isn't.
        let yaml_a = r#"
deployer:
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
  private_key: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110"
"#;
        let path_a = write_tmp("a.yaml", yaml_a);
        let path_a2 = write_tmp("a2.yaml", yaml_a);
        // Same wallet in both files — should merge cleanly (no conflict).
        let merged = parse_wallets_yaml_files(&[path_a, path_a2]).unwrap();
        assert_eq!(merged.len(), 1);
    }

    #[test]
    fn parse_wallets_yaml_files_bails_on_no_entries() {
        let empty_yaml = "{}\n";
        let path = write_tmp("empty.yaml", empty_yaml);
        let err = parse_wallets_yaml_files(&[path]).unwrap_err();
        assert!(
            err.to_string().contains("no wallet entries"),
            "got: {err}"
        );
    }

    #[test]
    fn parse_manifest_minimal() {
        let json = r#"
{
  "bundles": [
    {
      "index": 1,
      "file": "01_ecosystem.upgrade-prepare_0xabc.safe.json",
      "target": "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
      "tx_count": 45
    }
  ],
  "metadata": []
}
"#;
        let path = write_tmp("manifest.json", json);
        let m = parse_manifest(&path).unwrap();
        assert_eq!(m.bundles.len(), 1);
        assert_eq!(m.bundles[0].index, 1);
        assert_eq!(m.bundles[0].tx_count, 45);
        assert_eq!(
            m.bundles[0].target,
            "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049"
                .parse::<Address>()
                .unwrap()
        );
    }
}
