use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use ethers::utils::hex;
use serde::{Deserialize, Serialize};

use crate::common::governance_calls::decode_calls;
use crate::common::logger;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct GovernanceTomlToSimulatorArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Path to a protocol-ops governance TOML. Defaults to
    /// `upgrade-envs/v0.31.0-interopB/output/<env>/prepare/governance.toml`
    /// when `--env` is set.
    #[clap(long)]
    pub governance_toml: Option<PathBuf>,

    /// Transaction-simulator network name. Defaults to `mainnet` for
    /// `--env mainnet`, otherwise `sepolia`.
    #[clap(long)]
    pub network: Option<String>,

    /// Sender to put into every transaction. Defaults to the env's
    /// `owner_address` from `upgrade-envs/v0.31.0-interopB/<env>.toml`.
    #[clap(long)]
    pub from: Option<Address>,

    /// Optional output JSON path. When omitted, JSON is printed to stdout.
    #[clap(long)]
    pub out: Option<PathBuf>,

    /// Optional `prepare/manifest.json` path. When set, every bundle from the
    /// manifest is appended to the simulator output (one entry per inner Safe
    /// tx), tagged `bundle_<index>` with `from = bundle.target`. Use this when
    /// the upgrade ceremony involves Safe bundles outside the governance
    /// (`[governance_calls]`) bundle — e.g. CTM-admin operations like the
    /// ServerNotifier `ProxyAdmin.upgrade` that lands in its own per-CTM
    /// bundle signed by that CTM's admin owner.
    ///
    /// Defaults to `<env-out>/prepare/manifest.json` when `--env` is set and
    /// the manifest exists. Pass an explicit path to override.
    #[clap(long)]
    pub include_manifest: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct GovernanceCallsToml {
    governance_calls: GovernanceCalls,
}

#[derive(Debug, Deserialize)]
struct GovernanceCalls {
    stage0_calls: String,
    stage1_calls: String,
    stage2_calls: String,
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
    /// Seconds the local fork should advance via `evm_increaseTime` before
    /// this tx fires. Used for timer-protected gates like
    /// `GovernanceUpgradeTimer.checkDeadline()` — without it the local sim
    /// reverts with `DeadlineNotYetPassed()` because no wall time elapses
    /// between stage0's `startTimer(...)` and stage1's `checkDeadline()`.
    /// Picked up by the simulator at scripts/simulate.ts; see the
    /// `tx.timeIncrease` branch there.
    #[serde(rename = "timeIncrease", skip_serializing_if = "Option::is_none")]
    time_increase: Option<u64>,
    tag: String,
}

/// Selector → time-advance map. When a sim tx targets one of these,
/// emit a `timeIncrease` so the local fork's `block.timestamp` clears
/// the gate the call enforces.
const CHECK_DEADLINE_SELECTOR: &str = "0x43bf9936";

/// `governance_upgrade_timer_initial_delay` is env-specific (stage: 1200s,
/// mainnet: 172800s). Use a value comfortably larger than every env's delay
/// so the local fork always clears the gate.
const CHECK_DEADLINE_TIME_INCREASE_SECS: u64 = 200_000;

/// Subset of `prepare/manifest.json` needed to walk every Safe bundle.
#[derive(Debug, Deserialize)]
struct PrepareManifest {
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

/// Subset of a per-bundle Safe transaction file (Safe `TransactionBuilder`
/// schema). We only consume `to`, `value`, and `data`.
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

pub async fn run(args: GovernanceTomlToSimulatorArgs) -> anyhow::Result<()> {
    let env_cfg = args.topology.env_config()?;

    let governance_toml = match args.governance_toml {
        Some(path) => path,
        None => {
            let cfg = env_cfg.as_ref().ok_or_else(|| {
                anyhow::anyhow!("--governance-toml is required unless --env is set")
            })?;
            crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)?
                .join("prepare")
                .join("governance.toml")
        }
    };

    let network = args.network.unwrap_or_else(|| {
        env_cfg
            .as_ref()
            .filter(|cfg| cfg.env == "mainnet")
            .map(|_| "mainnet".to_string())
            .unwrap_or_else(|| "sepolia".to_string())
    });

    let from = match args.from {
        Some(addr) => addr,
        None => env_cfg
            .as_ref()
            .and_then(|cfg| cfg.owner_address())
            .ok_or_else(|| {
                anyhow::anyhow!("--from is required unless --env resolves an owner_address")
            })?,
    };

    // Resolve manifest path: explicit `--include-manifest` wins; otherwise
    // auto-discover `<env-out>/prepare/manifest.json` when `--env` is set.
    let manifest_path = match args.include_manifest {
        Some(path) => Some(path),
        None => env_cfg.as_ref().and_then(|cfg| {
            crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)
                .ok()
                .map(|base| base.join("prepare").join("manifest.json"))
                .filter(|p| p.is_file())
        }),
    };

    // Manifest bundles are emitted FIRST (deployer CREATE2 deploys + ownership
    // accepts), then governance stages 0/1/2. Order matters: the simulator's
    // local sim runs `eth_getCode` on every tx target, so the deployer's
    // CREATE2-deploys must land before stage0 calls them — otherwise stage0's
    // `startTimer()` against the new GovernanceUpgradeTimer reverts with
    // "EOA with non-empty calldata".
    let mut transactions = Vec::new();
    if let Some(ref manifest) = manifest_path {
        logger::info(format!(
            "Including manifest bundles from {}",
            manifest.display()
        ));
        let extra =
            manifest_to_simulator_transactions(manifest, &network).with_context(|| {
                format!("failed to expand manifest bundles {}", manifest.display())
            })?;
        transactions.extend(extra);
    }
    let governance =
        governance_toml_to_simulator_transactions(&governance_toml, &network, from).with_context(
            || {
                format!(
                    "failed to convert governance TOML {}",
                    governance_toml.display()
                )
            },
        )?;
    transactions.extend(governance);
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

/// Canonical Arachnid CREATE2 factory — same on every chain. Used to recognise
/// "deployer bundles" (any bundle with at least one tx whose `.to` is this
/// address) and to filter their non-CREATE2 txs out of the simulator scenario.
const CREATE2_FACTORY: &str = "0x4e59b44847b379578588920ca78fbf26c0b4956c";

/// Selectors of calls we drop from manifest-bundle expansion:
///
/// - `0x2c431917` = `scheduleTransparent(((address,uint256,bytes)[],bytes32,bytes32),uint256)`
///   on legacy `Governance.sol`. On a real-Sepolia-forked sim these would
///   always revert with `OperationExists()` because the schedule already
///   landed in a prior broadcast; the corresponding `executeInstant` still
///   runs and clears the gate using the schedule already on chain.
/// - `0x095ea7b3` = `approve(address,uint256)` — ZK base-token approves in
///   the deployer's bundle 7 priority-tx setup; the deployer EOA holds no
///   ZK on real Sepolia so these revert with insufficient balance.
/// - `0xd52471c1` = `requestL2TransactionDirect(...)` — Gateway L1→L2
///   priority requests that burn ZK base-token; same fund-availability
///   problem as the approves above, and the sim's L1-side checks don't
///   need the GW-side L2 state anyway.
const SKIPPED_SELECTORS: &[&str] = &["0x2c431917", "0x095ea7b3", "0xd52471c1"];

fn is_skipped_selector(data_hex: &str) -> bool {
    SKIPPED_SELECTORS.iter().any(|s| {
        data_hex
            .get(..s.len())
            .map(|prefix| prefix.eq_ignore_ascii_case(s))
            .unwrap_or(false)
    })
}

/// Walk `manifest.json`, open each `bundles[].file` (resolved relative to the
/// manifest directory), and emit one [`SimulatorTransaction`] per surviving
/// Safe tx with `from = bundle.target` and `tag = "bundle_<index>"`. Bundle
/// order is preserved; intra-bundle tx order is preserved.
///
/// **Deployer-bundle filtering**: any bundle that contains at least one call
/// to the CREATE2 factory is treated as a "deployer bundle" and its
/// non-CREATE2 txs (token approves, GW priority requests, …) are dropped from
/// the scenario. Those txs need real ZK base-token balance on the deployer
/// EOA, which the local-fork sim cannot conjure, and they are not preconditions
/// for the governance bundle anyway — only the CREATE2 deploys are.
fn manifest_to_simulator_transactions(
    manifest_path: &Path,
    network: &str,
) -> anyhow::Result<Vec<SimulatorTransaction>> {
    let manifest_dir = manifest_path.parent().ok_or_else(|| {
        anyhow::anyhow!("manifest path has no parent: {}", manifest_path.display())
    })?;
    let manifest_str = fs::read_to_string(manifest_path)
        .with_context(|| format!("failed to read {}", manifest_path.display()))?;
    let manifest: PrepareManifest = serde_json::from_str(&manifest_str)
        .with_context(|| format!("failed to parse {}", manifest_path.display()))?;

    let mut out = Vec::new();
    for bundle in &manifest.bundles {
        let bundle_path = manifest_dir.join(&bundle.file);
        let bundle_str = fs::read_to_string(&bundle_path)
            .with_context(|| format!("failed to read bundle {}", bundle_path.display()))?;
        let bundle_file: SafeBundleFile = serde_json::from_str(&bundle_str)
            .with_context(|| format!("failed to parse bundle {}", bundle_path.display()))?;

        let is_deployer_bundle = bundle_file
            .transactions
            .iter()
            .any(|tx| format!("{:#x}", tx.to) == CREATE2_FACTORY);

        let kept: Vec<&SafeBundleTx> = if is_deployer_bundle {
            bundle_file
                .transactions
                .iter()
                .filter(|tx| format!("{:#x}", tx.to) == CREATE2_FACTORY)
                .filter(|tx| !is_skipped_selector(&tx.data))
                .collect()
        } else {
            bundle_file
                .transactions
                .iter()
                .filter(|tx| !is_skipped_selector(&tx.data))
                .collect()
        };
        let kept_total = kept.len();
        let label = if bundle.steps.is_empty() {
            "(no steps)".to_string()
        } else {
            bundle.steps.join(",")
        };
        let suffix = if is_deployer_bundle {
            ", create2-only"
        } else {
            ""
        };
        for (idx, tx) in kept.into_iter().enumerate() {
            out.push(SimulatorTransaction {
                description: format!(
                    "protocol-ops manifest bundle {} ({}{}) tx {}/{}",
                    bundle.index,
                    label,
                    suffix,
                    idx + 1,
                    kept_total
                ),
                network: network.to_string(),
                from: format!("{:#x}", bundle.target),
                to: format!("{:#x}", tx.to),
                data: tx.data.clone(),
                value: tx.value.clone().unwrap_or_else(|| "0".to_string()),
                value_to_mint: None,
                time_increase: None,
                tag: format!("bundle_{}", bundle.index),
            });
        }
    }
    Ok(out)
}

fn governance_toml_to_simulator_transactions(
    path: &PathBuf,
    network: &str,
    from: Address,
) -> anyhow::Result<Vec<SimulatorTransaction>> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let parsed: GovernanceCallsToml =
        toml::from_str(&content).with_context(|| format!("failed to parse {}", path.display()))?;

    let stages = [
        (0u8, parsed.governance_calls.stage0_calls.as_str()),
        (1u8, parsed.governance_calls.stage1_calls.as_str()),
        (2u8, parsed.governance_calls.stage2_calls.as_str()),
    ];
    let mut out = Vec::new();
    let mut should_fund_sender = true;
    for (stage, encoded_calls) in stages {
        let calls = decode_calls(encoded_calls)
            .with_context(|| format!("failed to decode stage{stage}_calls"))?;
        for (idx, call) in calls.into_iter().enumerate() {
            let value_to_mint = should_fund_sender.then(|| "1".to_string());
            should_fund_sender = false;
            let data_hex = format!("0x{}", hex::encode(&call.data));
            let time_increase = if data_hex
                .get(..CHECK_DEADLINE_SELECTOR.len())
                .map(|prefix| prefix.eq_ignore_ascii_case(CHECK_DEADLINE_SELECTOR))
                .unwrap_or(false)
            {
                Some(CHECK_DEADLINE_TIME_INCREASE_SECS)
            } else {
                None
            };
            out.push(SimulatorTransaction {
                description: format!("protocol-ops governance stage{stage} call {}", idx + 1),
                network: network.to_string(),
                from: format!("{from:#x}"),
                to: format!("{:#x}", call.target),
                data: data_hex,
                value: call.value.to_string(),
                value_to_mint,
                time_increase,
                tag: format!("stage{stage}"),
            });
        }
    }
    Ok(out)
}
