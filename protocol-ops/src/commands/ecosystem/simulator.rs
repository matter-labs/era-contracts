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

    /// Optional `prepare/manifest.json` path. When set, every **Camp-B**
    /// bundle from the manifest is prepended to the simulator output: one
    /// entry per surviving Safe tx, tagged `bundle_<index>`,
    /// `from = bundle.target` (impersonated by the sim). Camp-B = signer
    /// we don't hold a key for.
    ///
    /// **Camp-A bundles are dropped entirely** — those are signed by an EOA
    /// we hold (passed via `--camp-a-signers`). Phase 2 of the regen pipeline
    /// broadcasts them to real Sepolia; the sim's fork inherits their effects
    /// from chain tip. Re-running them in the sim would revert (legacy-Gov
    /// `OperationMustBePending()`, already-deployed CREATE2 collisions, …).
    /// See `contracts/.claude/skills/regenerate-v31-stage-calldata/SKILL.md`
    /// ("Core principle") for the full reasoning.
    ///
    /// Defaults to `<env-out>/prepare/manifest.json` when `--env` is set and
    /// the manifest exists. Pass an explicit path to override.
    ///
    /// Per-tx filter still applied to Camp-B bundles ([`is_funded_call`]):
    /// `approve(address,uint256)` and `requestL2TransactionDirect(...)` need
    /// ZK base-token balance the local fork can't conjure.
    #[clap(long)]
    pub include_manifest: Option<PathBuf>,

    /// EOAs we hold private keys for. Bundles whose `target` (Safe signer) is
    /// in this set are classified Camp A and dropped from the sim — phase 2
    /// broadcasts them to real Sepolia. Comma-separated, e.g.
    /// `--camp-a-signers 0xAAA...,0xBBB...`. When omitted, we fall back to
    /// detecting Camp A as "any signer that signs at least one CREATE2-factory
    /// call" (heuristic — fine for v31 stage where our only EOA happens to be
    /// the CREATE2 deployer, but an explicit list is safer).
    #[clap(long, value_delimiter = ',', num_args = 1..)]
    pub camp_a_signers: Vec<Address>,
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

/// Canonical Arachnid CREATE2 factory — same on every chain. A bundle whose
/// signer issues even one call to this address is a deployer ("Camp-A")
/// bundle; its signer is presumed to be an EOA we hold a key for and
/// belongs to phase 2 (real-chain broadcast), not the sim.
const CREATE2_FACTORY: &str = "0x4e59b44847b379578588920ca78fbf26c0b4956c";

/// Selectors of calls an impersonated signer can't satisfy on the local fork
/// because they require ZK base-token balance:
///
/// - `0x095ea7b3` = `approve(address,uint256)` — ZK approves before priority
///   requests.
/// - `0xd52471c1` = `requestL2TransactionDirect(...)` — Gateway L1→L2 priority
///   requests that burn ZK.
/// - `0x24fd57fb` = `requestL2TransactionTwoBridges(...)` — same family as
///   above, used for two-bridges priority flows; also burns ZK.
///
/// Dropping these keeps the sim entries to L1-side state writes the fork can
/// actually execute. The sim doesn't need the GW-side L2 state.
const FUNDED_SELECTORS: &[&str] = &["0x095ea7b3", "0xd52471c1", "0x24fd57fb"];

fn is_funded_call(data_hex: &str) -> bool {
    FUNDED_SELECTORS.iter().any(|s| {
        data_hex
            .get(..s.len())
            .map(|prefix| prefix.eq_ignore_ascii_case(s))
            .unwrap_or(false)
    })
}

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

    // Manifest bundles come FIRST (Camp-B setup the sim impersonates), then
    // governance stages 0/1/2. Order matters: setup writes the state
    // (pendingOwner, verifier registry, etc.) that the gov calls then read.
    let mut transactions = Vec::new();
    if let Some(ref manifest) = manifest_path {
        logger::info(format!(
            "Including manifest bundles from {}",
            manifest.display()
        ));
        let extra = manifest_to_simulator_transactions(manifest, &network, &args.camp_a_signers)
            .with_context(|| format!("failed to expand manifest bundles {}", manifest.display()))?;
        transactions.extend(extra);
    }
    let governance = governance_toml_to_simulator_transactions(&governance_toml, &network, from)
        .with_context(|| {
            format!(
                "failed to convert governance TOML {}",
                governance_toml.display()
            )
        })?;
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

/// Walk `manifest.json`, drop every Camp-A bundle entirely, then emit one
/// [`SimulatorTransaction`] per surviving Camp-B tx with
/// `from = bundle.target` (sim impersonates) and `tag = "bundle_<index>"`.
/// Bundle and intra-bundle order are preserved. Camp-B txs go through the
/// [`is_funded_call`] filter so approve / GW priority calls (which need ZK
/// balance the fork can't conjure) get dropped.
///
/// Camp-A classification:
/// - explicit list via `--camp-a-signers` when non-empty, or
/// - fallback heuristic: "any signer that signs at least one CREATE2-factory
///   call". Fine for v31 stage where the only key we hold is the same EOA
///   that signs all CREATE2 deploys; for other envs pass the list explicitly.
fn manifest_to_simulator_transactions(
    manifest_path: &Path,
    network: &str,
    explicit_camp_a: &[Address],
) -> anyhow::Result<Vec<SimulatorTransaction>> {
    let manifest_dir = manifest_path.parent().ok_or_else(|| {
        anyhow::anyhow!("manifest path has no parent: {}", manifest_path.display())
    })?;
    let manifest_str = fs::read_to_string(manifest_path)
        .with_context(|| format!("failed to read {}", manifest_path.display()))?;
    let manifest: PrepareManifest = serde_json::from_str(&manifest_str)
        .with_context(|| format!("failed to parse {}", manifest_path.display()))?;

    // Pre-load every bundle file once — we may walk twice (signer auto-detect
    // + emission), and second-pass disk reads would be wasted I/O.
    let mut loaded: Vec<(&ManifestBundle, SafeBundleFile)> =
        Vec::with_capacity(manifest.bundles.len());
    for bundle in &manifest.bundles {
        let bundle_path = manifest_dir.join(&bundle.file);
        let bundle_str = fs::read_to_string(&bundle_path)
            .with_context(|| format!("failed to read bundle {}", bundle_path.display()))?;
        let bundle_file: SafeBundleFile = serde_json::from_str(&bundle_str)
            .with_context(|| format!("failed to parse bundle {}", bundle_path.display()))?;
        loaded.push((bundle, bundle_file));
    }

    // Resolve Camp-A signers — explicit list wins. Fallback heuristic:
    // "signs at least one CREATE2-factory call" classifies the address that
    // appears as `target` in any deployer bundle.
    let camp_a_signers: std::collections::HashSet<Address> = if !explicit_camp_a.is_empty() {
        explicit_camp_a.iter().copied().collect()
    } else {
        let mut auto: std::collections::HashSet<Address> = std::collections::HashSet::new();
        for (bundle, bundle_file) in &loaded {
            let touches_create2 = bundle_file
                .transactions
                .iter()
                .any(|tx| format!("{:#x}", tx.to) == CREATE2_FACTORY);
            if touches_create2 {
                auto.insert(bundle.target);
            }
        }
        auto
    };

    if !camp_a_signers.is_empty() {
        let pretty: Vec<String> = camp_a_signers.iter().map(|a| format!("{a:#x}")).collect();
        let source = if explicit_camp_a.is_empty() {
            "auto-detected via CREATE2-presence"
        } else {
            "from --camp-a-signers"
        };
        logger::info(format!(
            "Camp-A signers ({source}, broadcast in phase 2, dropped from sim): {}",
            pretty.join(", ")
        ));
    }

    // Emit Camp-B bundles, post-filtering funded calls. Track which signers
    // we've already minted ETH for so the first tx of each impersonated
    // signer carries a small `valueToMint` — without it the fork's account
    // for that address is empty and tx-simulator reverts with
    // `Insufficient funds for gas * price + value`.
    let mut funded_signers: std::collections::HashSet<Address> = std::collections::HashSet::new();
    let mut out = Vec::new();
    for (bundle, bundle_file) in &loaded {
        if camp_a_signers.contains(&bundle.target) {
            continue;
        }
        let kept: Vec<&SafeBundleTx> = bundle_file
            .transactions
            .iter()
            .filter(|tx| !is_funded_call(&tx.data))
            .collect();
        if kept.is_empty() {
            continue;
        }
        let kept_total = kept.len();
        let label = if bundle.steps.is_empty() {
            "(no steps)".to_string()
        } else {
            bundle.steps.join(",")
        };
        for (idx, tx) in kept.into_iter().enumerate() {
            let value_to_mint = if funded_signers.insert(bundle.target) {
                Some("1".to_string())
            } else {
                None
            };
            out.push(SimulatorTransaction {
                description: format!(
                    "protocol-ops manifest bundle {} ({}) tx {}/{}",
                    bundle.index,
                    label,
                    idx + 1,
                    kept_total
                ),
                network: network.to_string(),
                from: format!("{:#x}", bundle.target),
                to: format!("{:#x}", tx.to),
                data: tx.data.clone(),
                value: tx.value.clone().unwrap_or_else(|| "0".to_string()),
                value_to_mint,
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
            let data_hex = format!("0x{}", hex::encode(&call.data));
            // Funded calls (approves + GW priority requests) need ZK
            // base-token balance the local fork can't conjure for PUH; drop
            // them. The real-chain ceremony funds PUH ahead of these.
            if is_funded_call(&data_hex) {
                continue;
            }
            let value_to_mint = should_fund_sender.then(|| "1".to_string());
            should_fund_sender = false;
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
