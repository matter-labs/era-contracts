use std::collections::HashMap;
use std::path::{Path, PathBuf};

use alloy::primitives::Address;
use alloy::signers::local::PrivateKeySigner;
use anyhow::{bail, Context, Result};
use clap::Parser;

use crate::commands::dev::execute_safe::{execute_one_bundle, parse_gwei};
use crate::common::{anvil::set_balance, logger, preflight::is_local_rpc, PrivateKey};

/// Apply every bundle listed in a `manifest.json` file, routing each one to the
/// correct signer.
///
/// `manifest.json` is the file written by `bootstrap` / `apply` into their
/// `--out` directory. Each entry has a `target` (the expected signer address)
/// and a `file` (relative path to the Safe Transaction Builder JSON). This
/// command derives an Ethereum address from each `--private-key` supplied,
/// matches it to the `target`, and replays the bundle's transactions under that
/// key.
///
/// Supply all potential signing keys up front — either via repeated
/// `--private-key` flags or by pointing `--wallets` at a `wallets.yaml`.
/// If a bundle's target cannot be matched to any supplied key, the command
/// fails with a list of known signer addresses to help diagnose the mismatch.
///
/// # Example
///
/// ```text
/// protocol-ops dev execute-manifest \
///   --manifest out/manifest.json \
///   --private-key 0xdeployer_key \
///   --wallets wallets.yaml \
///   --l1-rpc-url http://localhost:8545
/// ```
#[derive(Debug, Clone, Parser)]
pub struct DevExecuteManifestArgs {
    /// Path to `manifest.json` (produced by bootstrap/apply in their `--out` dir).
    #[arg(long, default_value = "out/manifest.json")]
    pub manifest: PathBuf,

    /// Private key(s) of potential signers. Can be repeated.
    /// The correct key for each bundle is chosen by matching the derived address
    /// to the bundle's `target` field.
    #[arg(long = "private-key", action = clap::ArgAction::Append)]
    pub private_keys: Vec<PrivateKey>,

    /// Path to wallets.yaml — all private keys found in the file are added to
    /// the signer pool. Combine with `--private-key` to supply the deployer key.
    #[arg(long)]
    pub wallets: Option<PathBuf>,

    /// L1 RPC URL.
    #[arg(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Fund each bundle's target address via `anvil_setBalance` before applying.
    /// Defaults to true when `--l1-rpc-url` is a localhost URL. Set
    /// `--fund-targets=false` when targeting a non-Anvil node (production).
    #[arg(long, default_value = None)]
    pub fund_targets: Option<bool>,

    /// Minimum legacy gas price in gwei. The effective price is
    /// `max(3 x eth_gasPrice, floor)`, resolved once per bundle. Lower it on
    /// mainnet when the base fee is far below the 5 gwei default.
    #[arg(long = "gas-price-floor-gwei", default_value = "5", value_parser = parse_gwei)]
    pub gas_price_floor_wei: u128,
}

pub async fn run(args: DevExecuteManifestArgs) -> Result<()> {
    let fund = args
        .fund_targets
        .unwrap_or_else(|| is_local_rpc(&args.l1_rpc_url));
    let keys: Vec<String> = args
        .private_keys
        .iter()
        .map(|k| k.expose().to_string())
        .collect();
    apply_manifest(
        &args.manifest,
        &keys,
        args.wallets.as_deref(),
        &args.l1_rpc_url,
        fund,
        args.gas_price_floor_wei,
    )
    .await
}

/// Apply all bundles in `manifest_path`, resolving signers from `private_keys`
/// and optionally from a `wallets.yaml` file.
pub async fn apply_manifest(
    manifest_path: &Path,
    private_keys: &[String],
    wallets_path: Option<&Path>,
    l1_rpc_url: &str,
    fund_targets: bool,
    gas_price_floor_wei: u128,
) -> Result<()> {
    apply_manifest_from(
        manifest_path,
        0,
        private_keys,
        wallets_path,
        l1_rpc_url,
        fund_targets,
        gas_price_floor_wei,
    )
    .await
}

/// Apply only the bundles at positions `[start_index..]` in the manifest.
/// Used by `apply --broadcast` to skip bundles written by earlier commands
/// (e.g. ecosystem bundles from `bootstrap`).
pub async fn apply_manifest_from(
    manifest_path: &Path,
    start_index: usize,
    private_keys: &[String],
    wallets_path: Option<&Path>,
    l1_rpc_url: &str,
    fund_targets: bool,
    gas_price_floor_wei: u128,
) -> Result<()> {
    let key_map = build_key_map(private_keys, wallets_path)?;

    let manifest_content = std::fs::read_to_string(manifest_path)
        .with_context(|| format!("reading {}", manifest_path.display()))?;
    let manifest: serde_json::Value =
        serde_json::from_str(&manifest_content).context("parsing manifest.json")?;

    let all_bundles = manifest["bundles"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("manifest.json: missing bundles array"))?;

    let new_bundles = &all_bundles[start_index.min(all_bundles.len())..];
    if new_bundles.is_empty() {
        logger::info("No new bundles to apply.");
        return Ok(());
    }

    let manifest_dir = manifest_path.parent().unwrap_or_else(|| Path::new("."));

    logger::info(format!("Applying {} bundle(s)...", new_bundles.len()));

    for (i, bundle) in new_bundles.iter().enumerate() {
        let file = bundle["file"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("manifest bundle #{i} missing `file`"))?;
        let target_str = bundle["target"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("manifest bundle #{i} missing `target`"))?;

        let target: Address = target_str.parse().with_context(|| {
            format!("manifest bundle #{i} target is not a valid address: {target_str}")
        })?;

        let key = key_map.get(&target).ok_or_else(|| {
            let known: Vec<String> = key_map.keys().map(|a| format!("{a:#x}")).collect();
            anyhow::anyhow!(
                "No private key provided for bundle #{i} target {target:#x}.\n\
                 Known signers: {}\n\
                 Pass the missing key via --private-key or --wallets.",
                if known.is_empty() {
                    "(none)".to_string()
                } else {
                    known.join(", ")
                }
            )
        })?;

        let bundle_path = manifest_dir.join(file);

        if fund_targets {
            logger::info(format!("  funding {target:#x} via anvil_setBalance..."));
            set_balance(l1_rpc_url, target).await.with_context(|| {
                format!(
                    "anvil_setBalance({target:#x}) failed — use --fund-targets=false for non-Anvil nodes"
                )
            })?;
        }

        execute_one_bundle(&bundle_path, l1_rpc_url, key, None, gas_price_floor_wei).await?;
    }

    logger::success("All bundles applied.");
    Ok(())
}

/// Count bundles currently listed in `manifest.json`. Returns 0 if the file
/// does not exist or cannot be parsed.
pub fn count_manifest_bundles(manifest_path: &Path) -> usize {
    std::fs::read_to_string(manifest_path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v["bundles"].as_array().map(|a| a.len()))
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Key resolution helpers (shared with apply.rs)
// ---------------------------------------------------------------------------

/// Build a map of Ethereum address → private key from a list of raw hex keys
/// and an optional wallets.yaml file.
pub fn build_key_map(
    private_keys: &[String],
    wallets_path: Option<&Path>,
) -> Result<HashMap<Address, String>> {
    let mut all_keys: Vec<String> = private_keys.to_vec();

    if let Some(path) = wallets_path {
        all_keys.extend(extract_keys_from_wallets(path)?);
    }

    if all_keys.is_empty() {
        bail!("No private keys provided. Use --private-key or --wallets.");
    }

    let mut map = HashMap::new();
    for key in &all_keys {
        let pk_str = key.strip_prefix("0x").unwrap_or(key);
        let pk_bytes = hex::decode(pk_str)
            .with_context(|| "invalid private key hex (key redacted)".to_string())?;
        let signer = PrivateKeySigner::from_slice(&pk_bytes)
            .with_context(|| "invalid private key bytes (key redacted)".to_string())?;
        map.insert(signer.address(), key.clone());
    }

    Ok(map)
}

/// Read a `wallets.yaml` file and recursively extract every value stored under
/// a key named `private_key` or ending with `_sk`.
fn extract_keys_from_wallets(path: &Path) -> Result<Vec<String>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading wallets file {}", path.display()))?;
    let value: serde_yaml::Value = serde_yaml::from_str(&content)
        .with_context(|| format!("parsing wallets file {}", path.display()))?;
    let mut keys = Vec::new();
    collect_private_keys(&value, &mut keys);
    Ok(keys)
}

fn collect_private_keys(value: &serde_yaml::Value, out: &mut Vec<String>) {
    match value {
        serde_yaml::Value::Mapping(map) => {
            for (k, v) in map {
                let key_str = k.as_str().unwrap_or("");
                if (key_str == "private_key" || key_str.ends_with("_sk")) && v.is_string() {
                    if let Some(s) = v.as_str() {
                        if !s.is_empty() {
                            out.push(s.to_string());
                        }
                    }
                } else {
                    collect_private_keys(v, out);
                }
            }
        }
        serde_yaml::Value::Sequence(seq) => {
            for item in seq {
                collect_private_keys(item, out);
            }
        }
        _ => {}
    }
}
