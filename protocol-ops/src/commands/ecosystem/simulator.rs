use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use ethers::abi::{decode as abi_decode, ParamType};
use ethers::types::Address;
use ethers::utils::hex;
use serde::{Deserialize, Serialize};

use crate::common::governance_calls::decode_calls;
use crate::common::logger;

/// Optional human-description registry. Loaded from a TOML at
/// `<env>/sim-descriptions.toml` (auto-discovered from `--env`) or via an
/// explicit `--descriptions` flag. Each `[[entries]]` matches a sim tx by
/// `(target, selector)` plus an optional discriminator — first matching
/// entry wins; non-matching txs keep their auto-generated description.
///
/// Discriminators:
/// - `arg0_address`: the first 32-byte word after the selector, decoded as
///   an address. Disambiguates same-`(target, selector)` calls with
///   different first args (e.g. `TPA.upgrade(<proxy>, <impl>)` across
///   multiple proxies in stage 1).
/// - `inner_target` + `inner_selector`: for *wrapper* selectors
///   (`ChainAdmin.multicall`, legacy `Governance.scheduleTransparent` /
///   `executeInstant`), match against the FIRST inner call's target and/or
///   selector. Used for the bundle-1 legacy-Gov ceremony pairs and the
///   ChainAdmin multicalls in bundles 3/4.
#[derive(Debug, Default, Deserialize)]
struct SimDescriptionRegistry {
    #[serde(default)]
    entries: Vec<SimDescriptionEntry>,
}

#[derive(Debug, Deserialize)]
struct SimDescriptionEntry {
    target: Address,
    selector: String,
    /// First 32-byte word after the selector, interpreted as `address`.
    /// Used for plain `f(address, ...)` calls (e.g. `TPA.upgrade(proxy, impl)`).
    #[serde(default)]
    arg0_address: Option<Address>,
    /// `Bridgehub.requestL2TransactionDirect(L2TransactionRequestDirect)` —
    /// `l2Contract` is word 3 of the tuple (after offset/chainId/mintValue).
    /// Only meaningful when `selector = 0xd52471c1`.
    #[serde(default)]
    l2_contract: Option<Address>,
    /// `Bridgehub.requestL2TransactionTwoBridges(L2TransactionRequestTwoBridgesOuter)` —
    /// `secondBridgeAddress` is word 7 of the tuple.
    /// Only meaningful when `selector = 0x24fd57fb`.
    #[serde(default)]
    second_bridge_address: Option<Address>,
    /// For wrapper selectors (`multicall`, `scheduleTransparent`,
    /// `executeInstant`) — match the first inner call's target.
    #[serde(default)]
    inner_target: Option<Address>,
    /// For wrapper selectors — match the first inner call's 4-byte selector.
    #[serde(default)]
    inner_selector: Option<String>,
    desc: String,
}

impl SimDescriptionRegistry {
    fn lookup(&self, target: Address, data_hex: &str) -> Option<String> {
        let selector = data_hex.get(..10)?;
        let inner = parse_first_inner_call(data_hex);
        for entry in &self.entries {
            if entry.target != target {
                continue;
            }
            if !entry.selector.eq_ignore_ascii_case(selector) {
                continue;
            }
            if let Some(want) = entry.arg0_address {
                let arg0_hex = data_hex.get(10..74)?;
                let parsed: Address = format!("0x{}", &arg0_hex[24..]).parse().ok()?;
                if parsed != want {
                    continue;
                }
            }
            // requestL2TransactionDirect: l2Contract at word 3 after the selector.
            if let Some(want) = entry.l2_contract {
                let word_start = 10 + 3 * 64;
                let word_hex = data_hex.get(word_start..word_start + 64)?;
                let parsed: Address = format!("0x{}", &word_hex[24..]).parse().ok()?;
                if parsed != want {
                    continue;
                }
            }
            // requestL2TransactionTwoBridges: secondBridgeAddress at word 7.
            if let Some(want) = entry.second_bridge_address {
                let word_start = 10 + 7 * 64;
                let word_hex = data_hex.get(word_start..word_start + 64)?;
                let parsed: Address = format!("0x{}", &word_hex[24..]).parse().ok()?;
                if parsed != want {
                    continue;
                }
            }
            if entry.inner_target.is_some() || entry.inner_selector.is_some() {
                let (inner_target, inner_selector) = inner.as_ref()?;
                if let Some(want) = entry.inner_target {
                    if *inner_target != want {
                        continue;
                    }
                }
                if let Some(ref want_sel) = entry.inner_selector {
                    if !want_sel.eq_ignore_ascii_case(inner_selector) {
                        continue;
                    }
                }
            }
            return Some(entry.desc.clone());
        }
        None
    }
}

/// For wrapper calls — `ChainAdmin.multicall`, `Governance.scheduleTransparent`,
/// `Governance.executeInstant` — return the first inner `Call`'s target and
/// 4-byte selector. Returns `None` for unrecognised wrappers (the registry
/// then falls back to plain `(target, selector)` matching).
fn parse_first_inner_call(data_hex: &str) -> Option<(Address, String)> {
    let bytes = hex::decode(data_hex.trim_start_matches("0x")).ok()?;
    if bytes.len() < 4 {
        return None;
    }
    let selector = u32::from_be_bytes(bytes[..4].try_into().ok()?);
    let body = &bytes[4..];

    let call_type = ParamType::Tuple(vec![
        ParamType::Address,
        ParamType::Uint(256),
        ParamType::Bytes,
    ]);
    let operation_type = ParamType::Tuple(vec![
        ParamType::Array(Box::new(call_type.clone())),
        ParamType::FixedBytes(32),
        ParamType::FixedBytes(32),
    ]);

    let calls_array = match selector {
        // multicall((address,uint256,bytes)[], bool)
        0x69340beb => {
            let tokens = abi_decode(
                &[ParamType::Array(Box::new(call_type)), ParamType::Bool],
                body,
            )
            .ok()?;
            tokens.into_iter().next()?.into_array()?
        }
        // scheduleTransparent((Call[], bytes32, bytes32), uint256)
        0x2c431917 => {
            let tokens = abi_decode(&[operation_type, ParamType::Uint(256)], body).ok()?;
            tokens.into_iter().next()?.into_tuple()?.into_iter().next()?.into_array()?
        }
        // executeInstant((Call[], bytes32, bytes32))
        0x95218ecd => {
            let tokens = abi_decode(&[operation_type], body).ok()?;
            tokens.into_iter().next()?.into_tuple()?.into_iter().next()?.into_array()?
        }
        _ => return None,
    };

    let first = calls_array.into_iter().next()?.into_tuple()?;
    let mut it = first.into_iter();
    let target = it.next()?.into_address()?;
    let _value = it.next()?;
    let inner_data = it.next()?.into_bytes()?;
    if inner_data.len() < 4 {
        return None;
    }
    Some((target, format!("0x{}", hex::encode(&inner_data[..4]))))
}

fn load_descriptions(path: Option<&Path>) -> SimDescriptionRegistry {
    let path = match path {
        Some(p) => p,
        None => return SimDescriptionRegistry::default(),
    };
    if !path.exists() {
        return SimDescriptionRegistry::default();
    }
    let raw = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(err) => {
            logger::info(format!(
                "Couldn't read {} ({err}); using auto-generated descriptions",
                path.display()
            ));
            return SimDescriptionRegistry::default();
        }
    };
    match toml::from_str::<SimDescriptionRegistry>(&raw) {
        Ok(reg) => {
            logger::info(format!(
                "Loaded {} sim description override(s) from {}",
                reg.entries.len(),
                path.display()
            ));
            reg
        }
        Err(err) => {
            logger::info(format!(
                "Couldn't parse {} ({err}); using auto-generated descriptions",
                path.display()
            ));
            SimDescriptionRegistry::default()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct GovernanceTomlToSimulatorArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Path to a protocol-ops governance TOML. Defaults to
    /// `upgrade-envs/v0.31.0-interopB/output/<env>/ecosystem.toml`
    /// when `--env` is set — that's where `upgrade-prepare-all` writes the
    /// merged TOML (canonical tracked path).
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

    /// Optional path to a `sim-descriptions.toml` that overrides each
    /// emitted tx's `description` field with a human-readable string keyed by
    /// `(target, selector)` (+ optional discriminators). Auto-discovered at
    /// `upgrade-envs/v0.31.0-interopB/<env>/sim-descriptions.toml` when
    /// `--env` is set and the file exists.
    #[clap(long)]
    pub descriptions: Option<PathBuf>,
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

/// ETH (wei) minted to the governance sender (PUH) at the first stage-2 call
/// so the `requestL2TransactionDirect{value: y}` / `...TwoBridges{value: y}`
/// priority requests have msg.value coverage. 10 ETH is well above the
/// aggregate `priority_txs_l2_gas_limit * max_expected_l1_gas_price` budget
/// across the v31 stage's stage-2 L1→L2 chain.
const STAGE2_PUH_FUND_WEI: &str = "10000000000000000000";

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
                .join("ecosystem.toml")
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

    // Resolve descriptions registry: explicit `--descriptions` wins; otherwise
    // auto-discover the file alongside the env config TOML (one level up from
    // `<env-out>/`). For the v31 stage env that's
    // `upgrade-envs/v0.31.0-interopB/sim-descriptions.toml`.
    let descriptions_path = args.descriptions.or_else(|| {
        env_cfg.as_ref().and_then(|cfg| {
            crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)
                .ok()
                .and_then(|out| out.parent().map(|p| p.to_path_buf()))
                .and_then(|out_parent| out_parent.parent().map(|p| p.to_path_buf()))
                .map(|root| root.join("sim-descriptions.toml"))
                .filter(|p| p.is_file())
        })
    });
    let descriptions = load_descriptions(descriptions_path.as_deref());

    // Manifest bundles come FIRST (Camp-B setup the sim impersonates), then
    // governance stages 0/1/2. Order matters: setup writes the state
    // (pendingOwner, verifier registry, etc.) that the gov calls then read.
    let mut transactions = Vec::new();
    if let Some(ref manifest) = manifest_path {
        logger::info(format!(
            "Including manifest bundles from {}",
            manifest.display()
        ));
        let extra = manifest_to_simulator_transactions(manifest, &network, &args.camp_a_signers, &descriptions)
            .with_context(|| format!("failed to expand manifest bundles {}", manifest.display()))?;
        transactions.extend(extra);
    }
    let governance = governance_toml_to_simulator_transactions(&governance_toml, &network, from, &descriptions)
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
/// [`SimulatorTransaction`] per Camp-B tx with `from = bundle.target` (sim
/// impersonates) and `tag = "bundle_<index>"`. Bundle and intra-bundle order
/// are preserved. No per-tx filter — L1→L2 priority calls stay in the JSON
/// for sec-review visibility even if they revert at execution.
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
    descriptions: &SimDescriptionRegistry,
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

    // Emit Camp-B bundles in full — including any L1→L2 priority requests.
    // Earlier behavior dropped `approve` / `requestL2TransactionDirect` /
    // `...TwoBridges` on the grounds that the impersonated signer can't have
    // ZK base-token balance on a local fork, but that hid governance intent
    // from the sec-review surface. Keep them in the JSON; execution may
    // revert without a `tokenMint`-style primitive, but the record is what
    // reviewers need.
    //
    // Track which signers we've already minted ETH for so the first tx of
    // each impersonated signer carries a small `valueToMint` — without it
    // the fork's account is empty and tx-simulator reverts with
    // `Insufficient funds for gas * price + value`.
    let mut funded_signers: std::collections::HashSet<Address> = std::collections::HashSet::new();
    let mut out = Vec::new();
    for (bundle, bundle_file) in &loaded {
        if camp_a_signers.contains(&bundle.target) {
            continue;
        }
        let kept: Vec<&SafeBundleTx> = bundle_file.transactions.iter().collect();
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
            let _ = (label.as_str(), kept_total); // kept for `tag` parity; not used in description
            let description = descriptions
                .lookup(tx.to, &tx.data)
                .unwrap_or_else(|| {
                    let selector = tx.data.get(..10).unwrap_or("0x");
                    format!("[unlabelled] to={:#x} sel={selector} (bundle {} tx {})", tx.to, bundle.index, idx + 1)
                });
            out.push(SimulatorTransaction {
                description,
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
    descriptions: &SimDescriptionRegistry,
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
    let mut stage2_topup_pending = true;
    for (stage, encoded_calls) in stages {
        let calls = decode_calls(encoded_calls)
            .with_context(|| format!("failed to decode stage{stage}_calls"))?;
        for (idx, call) in calls.into_iter().enumerate() {
            let data_hex = format!("0x{}", hex::encode(&call.data));
            // Mint logic:
            //   - First stage-2 call → top up PUH with `STAGE2_PUH_FUND_WEI`
            //     so subsequent L1→L2 priority requests have msg.value.
            //   - Otherwise, first-ever call → seed PUH with 1 wei so the
            //     anvil account exists.
            //   - All later calls → no mint.
            let value_to_mint = if stage == 2 && stage2_topup_pending {
                stage2_topup_pending = false;
                should_fund_sender = false;
                Some(STAGE2_PUH_FUND_WEI.to_string())
            } else if should_fund_sender {
                should_fund_sender = false;
                Some("1".to_string())
            } else {
                None
            };
            let time_increase = if data_hex
                .get(..CHECK_DEADLINE_SELECTOR.len())
                .map(|prefix| prefix.eq_ignore_ascii_case(CHECK_DEADLINE_SELECTOR))
                .unwrap_or(false)
            {
                Some(CHECK_DEADLINE_TIME_INCREASE_SECS)
            } else {
                None
            };
            let description = descriptions
                .lookup(call.target, &data_hex)
                .unwrap_or_else(|| {
                    let selector = data_hex.get(..10).unwrap_or("0x");
                    format!("[unlabelled] stage{stage} call {} to={:#x} sel={selector}", idx + 1, call.target)
                });
            out.push(SimulatorTransaction {
                description,
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
