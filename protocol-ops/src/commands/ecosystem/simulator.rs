use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::dyn_abi::{DynSolType, DynSolValue};
use alloy::hex;
use alloy::primitives::Address;
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::governance_calls::decode_calls;
use crate::common::logger;

alloy::sol! {
    struct ChainAdminCall {
        address target;
        uint256 value;
        bytes data;
    }

    interface ChainAdminAbi {
        function multicall(ChainAdminCall[] _calls, bool _requireSuccess) external payable;
    }
}

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
///
/// Raw on-disk shape — address-typed fields accept either a `0x…` literal
/// or a label from `[labels]`. Resolved to the canonical [`SimDescriptionRegistry`]
/// at load time via [`build_registry`].
#[derive(Debug, Default, Deserialize)]
struct RawSimDescriptionRegistry {
    /// `name → address` map. Lets entry targets and address-typed
    /// discriminators refer to deployments by name so a salt rotation only
    /// requires updating this section (not every entry that referenced the
    /// rotated address).
    #[serde(default)]
    labels: std::collections::HashMap<String, Address>,
    #[serde(default)]
    entries: Vec<RawSimDescriptionEntry>,
}

#[derive(Debug, Deserialize)]
struct RawSimDescriptionEntry {
    target: String,
    selector: String,
    #[serde(default)]
    arg0_address: Option<String>,
    #[serde(default)]
    l2_contract: Option<String>,
    #[serde(default)]
    second_bridge_address: Option<String>,
    #[serde(default)]
    inner_target: Option<String>,
    #[serde(default)]
    inner_selector: Option<String>,
    desc: String,
}

#[derive(Debug, Default)]
struct SimDescriptionRegistry {
    entries: Vec<SimDescriptionEntry>,
}

#[derive(Debug)]
struct SimDescriptionEntry {
    target: Address,
    selector: String,
    /// First 32-byte word after the selector, interpreted as `address`.
    /// Used for plain `f(address, ...)` calls (e.g. `TPA.upgrade(proxy, impl)`).
    arg0_address: Option<Address>,
    /// `Bridgehub.requestL2TransactionDirect(L2TransactionRequestDirect)` —
    /// `l2Contract` is word 3 of the tuple (after offset/chainId/mintValue).
    /// Only meaningful when `selector = 0xd52471c1`.
    l2_contract: Option<Address>,
    /// `Bridgehub.requestL2TransactionTwoBridges(L2TransactionRequestTwoBridgesOuter)` —
    /// `secondBridgeAddress` is word 7 of the tuple.
    /// Only meaningful when `selector = 0x24fd57fb`.
    second_bridge_address: Option<Address>,
    /// For wrapper selectors (`multicall`, `scheduleTransparent`,
    /// `executeInstant`) — match the first inner call's target.
    inner_target: Option<Address>,
    /// For wrapper selectors — match the first inner call's 4-byte selector.
    inner_selector: Option<String>,
    desc: String,
}

/// Resolve a target string (either a `0x…` address literal or a label
/// defined in `[labels]`) to its canonical [`Address`].
fn resolve_address(
    value: &str,
    labels: &std::collections::HashMap<String, Address>,
) -> anyhow::Result<Address> {
    if value.starts_with("0x") || value.starts_with("0X") {
        value
            .parse::<Address>()
            .map_err(|err| anyhow::anyhow!("invalid address literal {value}: {err}"))
    } else {
        labels.get(value).copied().ok_or_else(|| {
            anyhow::anyhow!("unknown label `{value}` — add it to [labels] in sim-descriptions.toml")
        })
    }
}

/// Resolve all label references in a [`RawSimDescriptionRegistry`] into
/// canonical addresses. Returns an error on the first unknown label /
/// malformed literal, with a context string that points at the offending
/// entry index + field name so the developer can find it instantly.
fn build_registry(raw: RawSimDescriptionRegistry) -> anyhow::Result<SimDescriptionRegistry> {
    use anyhow::Context;
    let labels = &raw.labels;
    let mut entries = Vec::with_capacity(raw.entries.len());
    for (i, e) in raw.entries.into_iter().enumerate() {
        let target = resolve_address(&e.target, labels)
            .with_context(|| format!("entries[{i}].target = `{}`", e.target))?;
        let resolve_opt = |field: &str, v: Option<String>| -> anyhow::Result<Option<Address>> {
            v.map(|s| {
                resolve_address(&s, labels).with_context(|| format!("entries[{i}].{field} = `{s}`"))
            })
            .transpose()
        };
        entries.push(SimDescriptionEntry {
            target,
            selector: e.selector,
            arg0_address: resolve_opt("arg0_address", e.arg0_address)?,
            l2_contract: resolve_opt("l2_contract", e.l2_contract)?,
            second_bridge_address: resolve_opt("second_bridge_address", e.second_bridge_address)?,
            inner_target: resolve_opt("inner_target", e.inner_target)?,
            inner_selector: e.inner_selector,
            desc: e.desc,
        });
    }
    Ok(SimDescriptionRegistry { entries })
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
/// `Governance.executeInstant` / `Governance.execute` — return the first inner `Call`'s target and
/// 4-byte selector. Returns `None` for unrecognised wrappers (the registry
/// then falls back to plain `(target, selector)` matching).
fn parse_first_inner_call(data_hex: &str) -> Option<(Address, String)> {
    let bytes = hex::decode(data_hex.trim_start_matches("0x")).ok()?;
    if bytes.len() < 4 {
        return None;
    }
    let selector = u32::from_be_bytes(bytes[..4].try_into().ok()?);
    let body = &bytes[4..];

    let call_type = DynSolType::Tuple(vec![
        DynSolType::Address,
        DynSolType::Uint(256),
        DynSolType::Bytes,
    ]);
    let operation_type = DynSolType::Tuple(vec![
        DynSolType::Array(Box::new(call_type.clone())),
        DynSolType::FixedBytes(32),
        DynSolType::FixedBytes(32),
    ]);

    let first_param = match selector {
        // multicall((address,uint256,bytes)[], bool)
        0x69340beb => {
            let params = DynSolType::Tuple(vec![
                DynSolType::Array(Box::new(call_type)),
                DynSolType::Bool,
            ])
            .abi_decode_params(body)
            .ok()?;
            into_tuple(params)?.into_iter().next()?
        }
        // scheduleTransparent((Call[], bytes32, bytes32), uint256)
        0x2c431917 => {
            let params = DynSolType::Tuple(vec![operation_type, DynSolType::Uint(256)])
                .abi_decode_params(body)
                .ok()?;
            // First param is the Operation tuple; its first field is `Call[]`.
            into_tuple(into_tuple(params)?.into_iter().next()?)?
                .into_iter()
                .next()?
        }
        // executeInstant((Call[], bytes32, bytes32)) / execute((Call[], bytes32, bytes32))
        // Same ABI (a single `Operation` tuple param) — only the selector differs
        // (executeInstant = onlySecurityCouncil, execute = onlyOwnerOrSecurityCouncil).
        0x95218ecd | 0x74da756b => {
            let params = DynSolType::Tuple(vec![operation_type])
                .abi_decode_params(body)
                .ok()?;
            into_tuple(into_tuple(params)?.into_iter().next()?)?
                .into_iter()
                .next()?
        }
        _ => return None,
    };
    let calls_array = match first_param {
        DynSolValue::Array(calls) => calls,
        _ => return None,
    };

    let first = into_tuple(calls_array.into_iter().next()?)?;
    let mut it = first.into_iter();
    let target = match it.next()? {
        DynSolValue::Address(addr) => addr,
        _ => return None,
    };
    let _value = it.next()?;
    let inner_data = match it.next()? {
        DynSolValue::Bytes(b) => b,
        _ => return None,
    };
    if inner_data.len() < 4 {
        return None;
    }
    Some((target, format!("0x{}", hex::encode(&inner_data[..4]))))
}

/// Consume a `DynSolValue::Tuple`, returning its fields (or `None` for any
/// other variant).
fn into_tuple(value: DynSolValue) -> Option<Vec<DynSolValue>> {
    match value {
        DynSolValue::Tuple(items) => Some(items),
        _ => None,
    }
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
    let parsed: RawSimDescriptionRegistry = match toml::from_str(&raw) {
        Ok(r) => r,
        Err(err) => {
            logger::info(format!(
                "Couldn't parse {} ({err}); using auto-generated descriptions",
                path.display()
            ));
            return SimDescriptionRegistry::default();
        }
    };
    let label_count = parsed.labels.len();
    let entry_count = parsed.entries.len();
    match build_registry(parsed) {
        Ok(reg) => {
            logger::info(format!(
                "Loaded {entry_count} sim description override(s) and {label_count} label(s) from {}",
                path.display()
            ));
            reg
        }
        Err(err) => {
            logger::info(format!(
                "Failed to resolve labels in {} ({err:#}); using auto-generated descriptions",
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

    /// When set, write a curated, machine-independent **sim-inputs** set to this
    /// directory instead of emitting the sim JSON: a normalized `manifest.json`
    /// (just `bundles[]` — no `metadata[]`, which embeds local paths / the RPC
    /// URL / timestamps) plus the referenced Camp-B `*.safe.json` bundles.
    /// Camp-A (deployer) bundles are dropped, mirroring the sim's own
    /// classification, so the committed set is exactly what the emit consumes.
    ///
    /// This is the VPS handoff artifact: the regen box commits `<dir>` alongside
    /// `ecosystem.toml`, and a local emit then reproduces the sim purely from
    /// git. See `.claude/skills/fix-calldata-bug`. Short-circuits sim emission.
    #[clap(long)]
    pub emit_sim_inputs: Option<PathBuf>,
}

/// Minimal view of `[ctms.<flavor>.ctm_admin_calls]` used only to derive the bundle tag for the matching manifest entry.
#[derive(Debug, Deserialize)]
struct CtmAdminCallsSection {
    chain_admin: Address,
    server_notifier_upgrade: String,
}

#[derive(Debug, Default, Deserialize)]
struct CtmFlavorSection {
    #[serde(default)]
    ctm_admin_calls: Option<CtmAdminCallsSection>,
}

#[derive(Debug, Deserialize)]
struct GovernanceCallsToml {
    governance_calls: GovernanceCalls,
    #[serde(default)]
    test_upgrade_calls: BTreeMap<String, String>,
    /// Per-CTM flavor sections used to label ChainAdmin manifest bundles.
    #[serde(default)]
    ctms: BTreeMap<String, CtmFlavorSection>,
}

/// Maps CTM flavor names (as they appear in the TOML) to the simulator tag.
const CTM_ADMIN_CALLS_FLAVOR_TAGS: &[(&str, &str)] = &[
    ("era", "ctm_admin_calls_era"),
    ("zksync_os", "ctm_admin_calls_zkos"),
];

type CtmAdminCallsTagKey = (Address, String);
type CtmAdminCallsTags = Vec<(CtmAdminCallsTagKey, String)>;

/// Builds `(chain_admin, multicall_calldata) → simulator tag` entries from the parsed TOML.
/// Testnet uses the same ChainAdmin for multiple CTM flavors, so the address
/// alone is not enough to distinguish Era and ZKsync OS admin-call bundles.
fn build_ctm_admin_calls_tags(parsed: &GovernanceCallsToml) -> anyhow::Result<CtmAdminCallsTags> {
    let mut tags = Vec::new();
    for (flavor, tag) in CTM_ADMIN_CALLS_FLAVOR_TAGS {
        if let Some(ctm) = parsed.ctms.get(*flavor) {
            if let Some(ref section) = ctm.ctm_admin_calls {
                tags.push((
                    (
                        section.chain_admin,
                        encode_chain_admin_multicall(&section.server_notifier_upgrade)
                            .with_context(|| {
                                format!("encoding ctm_admin_calls for flavor {flavor}")
                            })?,
                    ),
                    tag.to_string(),
                ));
            }
        }
    }
    Ok(tags)
}

fn encode_chain_admin_multicall(calls_hex: &str) -> anyhow::Result<String> {
    let calls = decode_calls(calls_hex)?;
    let calls = calls
        .into_iter()
        .map(|call| ChainAdminCall {
            target: call.target,
            value: call.value,
            data: call.data.into(),
        })
        .collect();
    let calldata = ChainAdminAbi::multicallCall {
        _calls: calls,
        _requireSuccess: true,
    }
    .abi_encode();

    Ok(format!("0x{}", hex::encode(calldata)))
}

fn ctm_admin_calls_tag<'a>(tags: &'a CtmAdminCallsTags, tx: &SafeBundleTx) -> Option<&'a str> {
    tags.iter()
        .find(|((to, data), _)| *to == tx.to && data == &tx.data)
        .map(|(_, tag)| tag.as_str())
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
    /// Transaction-simulator-only escape hatch for per-chain upgrade tests.
    /// When set, the simulator mutates the forked chain diamond storage so
    /// `totalBatchesExecuted == totalBatchesVerified == totalBatchesCommitted`
    /// before sending the tx. This must stay limited to `test_upgrade_*`
    /// transactions; it is not a real proposal action and must not be used for
    /// stage/bundle/create-chain calls.
    #[serde(
        rename = "emulateAllBatchesExecuted",
        skip_serializing_if = "Option::is_none"
    )]
    emulate_all_batches_executed: Option<bool>,
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
    // auto-discover. Normally prefer the committed `<env-out>/sim-inputs/manifest.json`
    // (the git-portable handoff set) over the per-run `<env-out>/prepare/manifest.json`.
    // BUT when *producing* sim-inputs (`--emit-sim-inputs`), source from `prepare/`
    // first — reading from `sim-inputs/` while `write_sim_inputs` truncates those same
    // files would self-overwrite the source to 0 bytes.
    let manifest_path = match args.include_manifest {
        Some(path) => Some(path),
        None => env_cfg.as_ref().and_then(|cfg| {
            crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)
                .ok()
                .and_then(|base| {
                    let sim_inputs = base.join("sim-inputs").join("manifest.json");
                    let prepare = base.join("prepare").join("manifest.json");
                    let candidates = if args.emit_sim_inputs.is_some() {
                        [prepare, sim_inputs]
                    } else {
                        [sim_inputs, prepare]
                    };
                    candidates.into_iter().find(|p| p.is_file())
                })
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

    // `--emit-sim-inputs`: write the curated, git-portable sim-inputs set and
    // stop. This is the VPS regen's handoff step — it has the prepare manifest
    // right there; a local emit later reproduces the sim from the committed set.
    if let Some(sim_inputs_dir) = args.emit_sim_inputs.as_ref() {
        let manifest = manifest_path.as_ref().ok_or_else(|| {
            anyhow::anyhow!(
                "--emit-sim-inputs needs a manifest; none found (pass --include-manifest or run with --env after prepare)"
            )
        })?;
        write_sim_inputs(manifest, &args.camp_a_signers, sim_inputs_dir)?;
        return Ok(());
    }

    // Parse the ecosystem TOML once up-front to identify CTM admin calls by
    // exact ChainAdmin calldata. This keeps shared-ChainAdmin environments
    // distinguishable and lets us emit CTM calls in TOML flavor order.
    let ctm_admin_calls_tags: CtmAdminCallsTags = {
        let content = fs::read_to_string(&governance_toml)
            .with_context(|| format!("failed to read {}", governance_toml.display()))?;
        let parsed: GovernanceCallsToml = toml::from_str(&content)
            .with_context(|| format!("failed to parse {}", governance_toml.display()))?;
        build_ctm_admin_calls_tags(&parsed)?
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
        let extra = manifest_to_simulator_transactions(
            manifest,
            &network,
            &args.camp_a_signers,
            &descriptions,
            &ctm_admin_calls_tags,
        )
        .with_context(|| format!("failed to expand manifest bundles {}", manifest.display()))?;
        transactions.extend(extra);
    }
    let governance =
        governance_toml_to_simulator_transactions(&governance_toml, &network, from, &descriptions)
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

/// Write a curated, machine-independent **sim-inputs** set into `out_dir`:
/// a normalized `manifest.json` (only `bundles[]` — no `metadata[]`, which
/// embeds local paths / the RPC URL / timestamps) plus the referenced Camp-B
/// `*.safe.json` bundles, copied verbatim. Camp-A (deployer) bundles are
/// dropped — same classification as [`manifest_to_simulator_transactions`] —
/// so the committed set is exactly what the emit consumes.
///
/// Bundle `file` fields stay bare filenames resolved relative to the manifest
/// dir, so the copied set is portable: commit `out_dir` and a local emit
/// reproduces the sim with no out-of-band copy. See the fix-calldata-bug skill.
fn write_sim_inputs(
    manifest_path: &Path,
    explicit_camp_a: &[Address],
    out_dir: &Path,
) -> anyhow::Result<()> {
    let manifest_dir = manifest_path.parent().ok_or_else(|| {
        anyhow::anyhow!("manifest path has no parent: {}", manifest_path.display())
    })?;
    let manifest: PrepareManifest = serde_json::from_str(
        &fs::read_to_string(manifest_path)
            .with_context(|| format!("failed to read {}", manifest_path.display()))?,
    )
    .with_context(|| format!("failed to parse {}", manifest_path.display()))?;

    // Load every bundle so we can classify Camp-A and copy Camp-B.
    let mut loaded: Vec<(ManifestBundle, SafeBundleFile)> =
        Vec::with_capacity(manifest.bundles.len());
    for bundle in manifest.bundles {
        let bundle_path = manifest_dir.join(&bundle.file);
        let bundle_file: SafeBundleFile = serde_json::from_str(
            &fs::read_to_string(&bundle_path)
                .with_context(|| format!("failed to read bundle {}", bundle_path.display()))?,
        )
        .with_context(|| format!("failed to parse bundle {}", bundle_path.display()))?;
        loaded.push((bundle, bundle_file));
    }

    // Camp-A classification — mirrors `manifest_to_simulator_transactions`:
    // explicit `--camp-a-signers` wins, else auto-detect "signs at least one
    // CREATE2-factory call".
    let camp_a: std::collections::HashSet<Address> = if !explicit_camp_a.is_empty() {
        explicit_camp_a.iter().copied().collect()
    } else {
        loaded
            .iter()
            .filter(|(_, bf)| {
                bf.transactions
                    .iter()
                    .any(|tx| format!("{:#x}", tx.to) == CREATE2_FACTORY)
            })
            .map(|(b, _)| b.target)
            .collect()
    };
    // The CREATE2-presence heuristic silently fails when prepare runs against a
    // fork where the contracts are already deployed (no CREATE2 calls in the
    // deployer's bundle) — the deployer then leaks into sim-inputs as Camp-B.
    // Zero detected Camp-A signers is almost always that bug: fail loudly so the
    // caller passes `--camp-a-signers <deployer>` rather than ship a wrong set.
    if explicit_camp_a.is_empty() && camp_a.is_empty() {
        anyhow::bail!(
            "no Camp-A signers detected (CREATE2-presence heuristic found none) — the \
             deployer would leak into sim-inputs. Re-run with explicit --camp-a-signers <deployer EOA> \
             (e.g. the broadcast signer). This commonly happens when prepare ran against an \
             already-deployed fork tip."
        );
    }

    fs::create_dir_all(out_dir)
        .with_context(|| format!("failed to create sim-inputs dir {}", out_dir.display()))?;

    let mut kept = Vec::new();
    for (bundle, _) in &loaded {
        if camp_a.contains(&bundle.target) {
            continue;
        }
        // Copy the Camp-B safe.json verbatim (bare filename → portable).
        let src = manifest_dir.join(&bundle.file);
        let dst = out_dir.join(&bundle.file);
        fs::copy(&src, &dst)
            .with_context(|| format!("failed to copy {} -> {}", src.display(), dst.display()))?;
        kept.push(serde_json::json!({
            "index": bundle.index,
            "file": bundle.file,
            "target": format!("{:#x}", bundle.target),
            "steps": bundle.steps.clone(),
        }));
    }

    let manifest_out = out_dir.join("manifest.json");
    let normalized = serde_json::to_string_pretty(&serde_json::json!({ "bundles": kept }))?;
    fs::write(&manifest_out, format!("{normalized}\n"))
        .with_context(|| format!("failed to write {}", manifest_out.display()))?;
    logger::info(format!(
        "Wrote {} Camp-B sim-input bundle(s) + normalized manifest to {}",
        kept.len(),
        out_dir.display()
    ));
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
    ctm_admin_calls_tags: &CtmAdminCallsTags,
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
        let ordered_ctm_admin_txs: Vec<&SafeBundleTx> = ctm_admin_calls_tags
            .iter()
            .filter_map(|((expected_to, expected_data), _)| {
                kept.iter()
                    .copied()
                    .find(|tx| tx.to == *expected_to && tx.data == *expected_data)
            })
            .collect();
        let mut ordered_ctm_admin_txs = ordered_ctm_admin_txs.into_iter();
        for (idx, tx) in kept.into_iter().enumerate() {
            let tx = if ctm_admin_calls_tag(ctm_admin_calls_tags, tx).is_some() {
                ordered_ctm_admin_txs.next().unwrap_or(tx)
            } else {
                tx
            };
            let value_to_mint = if funded_signers.insert(bundle.target) {
                Some("1".to_string())
            } else {
                None
            };
            let _ = (label.as_str(), kept_total); // kept for `tag` parity; not used in description
            let description = descriptions.lookup(tx.to, &tx.data).unwrap_or_else(|| {
                let selector = tx.data.get(..10).unwrap_or("0x");
                format!(
                    "[unlabelled] to={:#x} sel={selector} (bundle {} tx {})",
                    tx.to,
                    bundle.index,
                    idx + 1
                )
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
                emulate_all_batches_executed: None,
                tag: ctm_admin_calls_tag(ctm_admin_calls_tags, tx)
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("bundle_{}", bundle.index)),
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
                    format!(
                        "[unlabelled] stage{stage} call {} to={:#x} sel={selector}",
                        idx + 1,
                        call.target
                    )
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
                emulate_all_batches_executed: None,
                tag: format!("stage{stage}"),
            });
        }
    }

    append_test_upgrade_calls(&mut out, &parsed.test_upgrade_calls, network, descriptions)?;

    Ok(out)
}

fn append_test_upgrade_calls(
    out: &mut Vec<SimulatorTransaction>,
    test_upgrade_calls: &BTreeMap<String, String>,
    network: &str,
    descriptions: &SimDescriptionRegistry,
) -> anyhow::Result<()> {
    for (tag, encoded_calls) in test_upgrade_calls {
        if !tag.starts_with("test_") || tag.ends_with("_caller") {
            continue;
        }

        let caller_key = format!("{tag}_caller");
        let caller = test_upgrade_calls
            .get(&caller_key)
            .with_context(|| format!("missing [test_upgrade_calls].{caller_key}"))?
            .parse::<Address>()
            .with_context(|| format!("invalid [test_upgrade_calls].{caller_key} address"))?;
        let calls = decode_calls(encoded_calls)
            .with_context(|| format!("failed to decode [test_upgrade_calls].{tag}"))?;
        let emulate_all_batches_executed = tag.starts_with("test_upgrade_").then_some(true);

        for (idx, call) in calls.into_iter().enumerate() {
            let data_hex = format!("0x{}", hex::encode(&call.data));
            let description = descriptions
                .lookup(call.target, &data_hex)
                .unwrap_or_else(|| {
                    let selector = data_hex.get(..10).unwrap_or("0x");
                    format!(
                        "[unlabelled] {tag} call {} to={:#x} sel={selector}",
                        idx + 1,
                        call.target
                    )
                });
            out.push(SimulatorTransaction {
                description,
                network: network.to_string(),
                from: format!("{caller:#x}"),
                to: format!("{:#x}", call.target),
                data: data_hex,
                value: call.value.to_string(),
                value_to_mint: Some("1".to_string()),
                time_increase: None,
                emulate_all_batches_executed,
                tag: tag.to_string(),
            });
        }
    }

    Ok(())
}
