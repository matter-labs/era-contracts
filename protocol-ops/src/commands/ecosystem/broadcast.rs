//! `ecosystem upgrade-broadcast` — multi-bundle EOA dispatcher.
//!
//! Reads the `manifest.json` produced by `upgrade-prepare-all` and replays
//! every bundle file in order against any RPC (anvil fork OR real L1), each
//! under the matching signer's private key. The bundles are Safe Transaction
//! Builder–compatible JSON, but this command never touches Safe UI: every tx
//! is signed locally with the supplied EOA key and submitted via
//! `eth_sendRawTransaction`. That covers both deployer-EOA bundles and any
//! signer that happens to be a single-key EOA (stage's securityCouncil is
//! one such case — see `permanent-values/stage.toml`).
//!
//! Multisig-signer bundles are out of scope here: those need signatures
//! collected through Safe UI (or another off-chain coordination flow) and
//! the resulting `execTransaction` submitted separately.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use alloy::primitives::{Address, B256};
use alloy::signers::local::PrivateKeySigner;
use anyhow::Context;
use clap::Parser;
use serde::Deserialize;

use crate::commands::dev::execute_safe::{
    execute_one_bundle, execute_one_bundle_unlocked, GAS_PRICE_FLOOR_WEI,
};
use crate::common::logger;

#[derive(Debug, Clone, Parser)]
pub struct UpgradeBroadcastArgs {
    /// Path to a `manifest.json` produced by `ecosystem upgrade-prepare-all`.
    /// The manifest's `bundles[]` are dispatched in `index` order; each bundle
    /// file is resolved relative to the manifest's directory.
    #[clap(long)]
    pub manifest: PathBuf,

    /// L1 RPC URL. Use a real Sepolia/mainnet endpoint for production
    /// deployment, or an anvil fork URL for a dry run. The RPC is shared
    /// across every bundle in the manifest.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Per-signer private key in `0xADDR=0xHEX` form. Repeat the flag once
    /// per distinct `target` in the manifest. The address must match the
    /// bundle's `target`; the key is only used to sign that bundle's txs.
    /// Example: `--key 0x8f08…7EF=$DEPLOYER_KEY --key 0x5555…643c=$SC_KEY`.
    /// Required unless `--unlocked` is set.
    #[clap(long = "key", value_name = "ADDR=KEY")]
    pub keys: Vec<String>,

    /// Fork-rehearsal mode: dispatch every bundle via `eth_sendTransaction`
    /// with `from = bundle.target` instead of locally signing. Requires the
    /// RPC to be an anvil started with `--auto-impersonate` (or to have
    /// every bundle's `target` pre-impersonated via `anvil_impersonateAccount`).
    /// `--key` is ignored in this mode. Refuses to run against any chain id
    /// other than mainnet/Sepolia/L1-fork without an explicit override —
    /// safety net to avoid accidental impersonation attempts on real prod.
    #[clap(long)]
    pub unlocked: bool,

    /// Optional path to accumulate executed-tx logs across every bundle in the
    /// manifest. Same shape `dev execute-safe --out` produces. Consumed by
    /// `ecosystem verify-upgrade --executed-bundles <path>` so the verifier
    /// can reconstruct CREATE2 / TUPP deployments from a fork rehearsal.
    #[clap(long)]
    pub out: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    bundles: Vec<ManifestBundle>,
}

#[derive(Debug, Deserialize)]
struct ManifestBundle {
    file: String,
    index: u32,
    target: Address,
}

pub async fn run(args: UpgradeBroadcastArgs) -> anyhow::Result<()> {
    let manifest_path = args
        .manifest
        .canonicalize()
        .with_context(|| format!("manifest not found: {}", args.manifest.display()))?;
    let manifest_dir = manifest_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("manifest path has no parent dir"))?
        .to_path_buf();

    let raw = fs::read_to_string(&manifest_path)
        .with_context(|| format!("read {}", manifest_path.display()))?;
    let mut manifest: Manifest = serde_json::from_str(&raw).context("parse manifest.json")?;

    // Trust the manifest's index ordering — `prepare-all` writes bundles in
    // execution order, but we sort defensively in case future versions emit
    // them out of order (the index is the source of truth either way).
    manifest.bundles.sort_by_key(|b| b.index);
    if manifest.bundles.is_empty() {
        anyhow::bail!("manifest.bundles is empty");
    }

    let key_map = if args.unlocked {
        if !args.keys.is_empty() {
            logger::info("--unlocked is set; ignoring --key flags".to_string());
        }
        HashMap::new()
    } else {
        parse_keys(&args.keys)?
    };

    // Pre-flight: in keyed mode every required signer must have a key
    // supplied. Fail before we send any tx — partial broadcast on real L1 is
    // the worst outcome.
    if !args.unlocked {
        let mut missing: Vec<Address> = Vec::new();
        for bundle in &manifest.bundles {
            if !key_map.contains_key(&bundle.target) && !missing.contains(&bundle.target) {
                missing.push(bundle.target);
            }
        }
        if !missing.is_empty() {
            anyhow::bail!(
                "no `--key` supplied for signer(s): {}",
                missing
                    .iter()
                    .map(|a| format!("{a:#x}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
    }

    logger::step(format!(
        "Broadcasting {} bundle(s) from {} to {} ({})",
        manifest.bundles.len(),
        manifest_path.display(),
        args.l1_rpc_url,
        if args.unlocked {
            "unlocked / anvil-impersonate"
        } else {
            "EOA-signed"
        },
    ));

    let out_path = args.out.as_deref();
    for bundle in &manifest.bundles {
        let bundle_path = manifest_dir.join(&bundle.file);
        logger::info(format!(
            "Bundle {} / {} (target {:#x}, file {})",
            bundle.index,
            manifest.bundles.len(),
            bundle.target,
            bundle.file,
        ));
        if args.unlocked {
            execute_one_bundle_unlocked(&bundle_path, &args.l1_rpc_url, bundle.target, out_path)
                .await
                .with_context(|| format!("bundle #{} ({})", bundle.index, bundle.file))?;
        } else {
            let key = &key_map[&bundle.target];
            execute_one_bundle(
                &bundle_path,
                &args.l1_rpc_url,
                key,
                out_path,
                GAS_PRICE_FLOOR_WEI,
            )
            .await
            .with_context(|| format!("bundle #{} ({})", bundle.index, bundle.file))?;
        }
    }

    logger::success("All bundles broadcast successfully");
    Ok(())
}

/// Parse `--key 0xADDR=0xHEX` args into an `Address → key` map. Validates
/// each key by deriving the address it controls and checking it matches the
/// declared address — catches the common mistake of pasting the wrong
/// signer's key (the broadcast would otherwise produce txs from an
/// unauthorized sender, all of which would silently fail their auth checks
/// on real L1).
fn parse_keys(raw: &[String]) -> anyhow::Result<HashMap<Address, String>> {
    let mut map: HashMap<Address, String> = HashMap::new();
    for entry in raw {
        let (addr_str, key_str) = entry
            .split_once('=')
            .ok_or_else(|| anyhow::anyhow!("--key must be in form `0xADDR=0xHEX`, got: {entry}"))?;
        let declared: Address = addr_str
            .parse()
            .with_context(|| format!("--key address `{addr_str}` is not a valid address"))?;
        let pk_b256: B256 = key_str
            .parse()
            .with_context(|| format!("--key for {declared:#x} is not a valid 32-byte hex"))?;
        let wallet = PrivateKeySigner::from_bytes(&pk_b256)
            .with_context(|| format!("--key for {declared:#x} is not a valid signer"))?;
        let derived = wallet.address();
        if derived != declared {
            anyhow::bail!(
                "--key for {declared:#x} actually signs as {derived:#x}; refuse to broadcast under the wrong sender",
            );
        }
        if map.insert(declared, key_str.to_string()).is_some() {
            anyhow::bail!("duplicate --key for {declared:#x}");
        }
    }
    Ok(map)
}
