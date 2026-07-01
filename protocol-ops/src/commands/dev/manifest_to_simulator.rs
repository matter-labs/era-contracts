use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

/// Convert a protocol-ops Safe-bundle manifest into transaction-simulator JSON.
///
/// `manifest.json` is the file written by prepare-shape commands under their
/// `--out` directory. This command walks `bundles[]` in manifest order, loads
/// each referenced Safe Transaction Builder JSON file, and emits one simulator
/// transaction per Safe tx.
///
/// The simulator impersonates `from`, so each output transaction uses the
/// manifest bundle's `target` as `from`. To keep fresh fork accounts from
/// failing gas checks, the first transaction for each unique signer gets
/// `valueToMint`.
#[derive(Debug, Clone, Parser)]
pub struct DevManifestToSimulatorArgs {
    /// Path to `manifest.json`, or to the directory containing it.
    #[arg(long, default_value = "out/manifest.json")]
    pub manifest: PathBuf,

    /// Transaction-simulator network name.
    #[arg(long, default_value = "sepolia")]
    pub network: String,

    /// Optional output JSON path. When omitted, JSON is printed to stdout.
    #[arg(long)]
    pub out: Option<PathBuf>,

    /// Wei to mint to each unique impersonated signer on its first tx.
    #[arg(long, default_value = "1")]
    pub value_to_mint: String,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    bundles: Vec<ManifestBundle>,
}

#[derive(Debug, Deserialize)]
struct ManifestBundle {
    file: String,
    index: u32,
    #[serde(default)]
    steps: Vec<String>,
    target: Address,
}

#[derive(Debug, Deserialize)]
struct SafeBundleFile {
    transactions: Vec<SafeBundleTx>,
}

#[derive(Debug, Deserialize)]
struct SafeBundleTx {
    to: Address,
    #[serde(default)]
    value: Option<String>,
    data: String,
}

#[derive(Debug, Serialize)]
struct SimulatorTransaction {
    description: String,
    network: String,
    from: String,
    to: String,
    data: String,
    value: String,
    #[serde(rename = "valueToMint", skip_serializing_if = "Option::is_none")]
    value_to_mint: Option<String>,
    tag: String,
}

pub async fn run(args: DevManifestToSimulatorArgs) -> anyhow::Result<()> {
    let manifest_path = resolve_manifest_path(&args.manifest)?;
    let transactions =
        manifest_to_simulator_transactions(&manifest_path, &args.network, &args.value_to_mint)?;
    let body = serde_json::to_string_pretty(&transactions)?;

    if let Some(out) = args.out {
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create output dir {}", parent.display()))?;
        }
        fs::write(&out, format!("{body}\n"))
            .with_context(|| format!("failed to write {}", out.display()))?;
    } else {
        println!("{body}");
    }

    Ok(())
}

fn resolve_manifest_path(path: &Path) -> anyhow::Result<PathBuf> {
    if path.is_dir() {
        let manifest = path.join("manifest.json");
        if manifest.is_file() {
            return Ok(manifest);
        }
        anyhow::bail!(
            "directory {} does not contain manifest.json",
            path.display()
        );
    }

    if path.is_file() {
        return Ok(path.to_path_buf());
    }

    anyhow::bail!("manifest not found: {}", path.display());
}

fn manifest_to_simulator_transactions(
    manifest_path: &Path,
    network: &str,
    value_to_mint: &str,
) -> anyhow::Result<Vec<SimulatorTransaction>> {
    let manifest_dir = manifest_path.parent().ok_or_else(|| {
        anyhow::anyhow!("manifest path has no parent: {}", manifest_path.display())
    })?;
    let manifest: Manifest = serde_json::from_str(
        &fs::read_to_string(manifest_path)
            .with_context(|| format!("failed to read {}", manifest_path.display()))?,
    )
    .with_context(|| format!("failed to parse {}", manifest_path.display()))?;

    let mut funded_signers = HashSet::new();
    let mut out = Vec::new();

    for bundle in manifest.bundles {
        let bundle_path = manifest_dir.join(&bundle.file);
        let bundle_file: SafeBundleFile = serde_json::from_str(
            &fs::read_to_string(&bundle_path)
                .with_context(|| format!("failed to read bundle {}", bundle_path.display()))?,
        )
        .with_context(|| format!("failed to parse bundle {}", bundle_path.display()))?;

        let step_label = if bundle.steps.is_empty() {
            "bundle".to_string()
        } else {
            bundle.steps.join(",")
        };

        for (tx_index, tx) in bundle_file.transactions.into_iter().enumerate() {
            let selector = tx.data.get(..10).unwrap_or("0x");
            let mint = if funded_signers.insert(bundle.target) {
                Some(value_to_mint.to_string())
            } else {
                None
            };

            out.push(SimulatorTransaction {
                description: format!(
                    "{step_label}: to={:#x} sel={selector} (bundle {} tx {})",
                    tx.to,
                    bundle.index,
                    tx_index + 1
                ),
                network: network.to_string(),
                from: format!("{:#x}", bundle.target),
                to: format!("{:#x}", tx.to),
                data: tx.data,
                value: tx.value.unwrap_or_else(|| "0".to_string()),
                value_to_mint: mint,
                tag: format!("bundle_{}", bundle.index),
            });
        }
    }

    Ok(out)
}
