//! Reading the three transaction-list formats into a [`Runbook`].

use std::collections::BTreeMap;
use std::fs;
use std::path::{Component, Path, PathBuf};

use alloy::primitives::{Address, Bytes, U256};
use anyhow::Context;
use serde::Deserialize;
use serde_json::Value;

use super::decode::known_function;
use super::{Runbook, RunbookTx, SourceKind};

/// Chain ids the runbook names; any other id is shown as `chain <id>`.
const NETWORKS: [(u64, &str, &str); 2] = [
    (1, "Ethereum mainnet", "mainnet"),
    (11_155_111, "Sepolia", "sepolia"),
];

/// Directory of committed Safe-bundle sim inputs under `output/<env>/`; a manifest inside it
/// puts the runbook next to the directory, among the env's other outputs.
const SIM_INPUTS_DIR: &str = "sim-inputs";
const MANIFEST_FILE: &str = "manifest.json";

/// What the caller knows beyond the list itself.
#[derive(Debug, Clone, Default)]
pub struct LoadOptions {
    /// Expected chain id; must agree with the list if the list records one.
    pub chain_id: Option<u64>,
    /// Upgrade directory name, e.g. `v0.33.0-compiler`; inferred from an
    /// `upgrade-envs/<upgrade>/output/<env>/` source path when absent.
    pub upgrade: Option<String>,
    /// Environment name; inferred like `upgrade`.
    pub env: Option<String>,
    /// Heading override.
    pub title: Option<String>,
    /// Address names from outside the list (e.g. the env's permanent values). Names the list
    /// itself carries win.
    pub names: BTreeMap<Address, String>,
    /// Simulator lists only: drop txs whose tag starts with one of these prefixes.
    pub exclude_tags: Vec<String>,
    /// Extra bullets.
    pub notes: Vec<String>,
}

/// The formats [`load`] understands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InputFormat {
    EmergencyBoard,
    SafeManifest,
    Simulator,
}

/// Where the runbook for `input` goes by default: next to the input, or next to the
/// `sim-inputs/` directory for a manifest inside one.
pub fn default_runbook_path(input: &Path) -> anyhow::Result<PathBuf> {
    let input = resolve_input(input)?;
    let dir = input
        .parent()
        .ok_or_else(|| anyhow::anyhow!("{} has no parent directory", input.display()))?;
    let dir = match dir.file_name() {
        Some(name) if name == SIM_INPUTS_DIR => dir.parent().unwrap_or(dir),
        _ => dir,
    };
    Ok(dir.join(super::RUNBOOK_FILE))
}

/// A directory input means its `manifest.json`.
fn resolve_input(input: &Path) -> anyhow::Result<PathBuf> {
    let path = if input.is_dir() {
        input.join(MANIFEST_FILE)
    } else {
        input.to_path_buf()
    };
    anyhow::ensure!(path.is_file(), "input not found: {}", path.display());
    Ok(path)
}

/// Read the transaction list at `input` for a runbook written to `runbook_path`.
pub fn load(input: &Path, runbook_path: &Path, options: &LoadOptions) -> anyhow::Result<Runbook> {
    let input = fs::canonicalize(resolve_input(input)?)?;
    let runbook_dir = runbook_path
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(runbook_dir).with_context(|| format!("create {}", runbook_dir.display()))?;
    let runbook_dir = fs::canonicalize(runbook_dir)?;

    let raw = fs::read_to_string(&input).with_context(|| format!("read {}", input.display()))?;
    let json: Value =
        serde_json::from_str(&raw).with_context(|| format!("parse {} as JSON", input.display()))?;
    let (inferred_upgrade, inferred_env) = infer_upgrade_and_env(&input);
    let env = options.env.clone().or(inferred_env);
    let upgrade = options.upgrade.clone().or(inferred_upgrade);

    let loaded = match detect(&json).with_context(|| input.display().to_string())? {
        InputFormat::EmergencyBoard => load_emergency_board(json)?,
        InputFormat::SafeManifest => load_safe_manifest(json, &input, &runbook_dir)?,
        InputFormat::Simulator => load_simulator(json, &options.exclude_tags)?,
    };
    anyhow::ensure!(
        !loaded.txs.is_empty(),
        "{} lists no transactions",
        input.display()
    );

    let chain_id = match (loaded.chain_id, options.chain_id) {
        (Some(listed), Some(expected)) => {
            anyhow::ensure!(
                listed == expected,
                "{} is for chain {listed}, expected chain {expected}",
                input.display()
            );
            listed
        }
        (Some(id), None) | (None, Some(id)) => id,
        (None, None) => anyhow::bail!(
            "{} records no chain id; pass it (or the env) explicitly",
            input.display()
        ),
    };
    let title = options.title.clone().unwrap_or_else(|| {
        default_title(
            upgrade.as_deref(),
            env.as_deref(),
            loaded.subject.as_deref(),
            &network_name(chain_id),
        )
    });
    let mut names = options.names.clone();
    names.extend(loaded.names);

    Ok(Runbook {
        title,
        source_link: relative_link(&runbook_dir, &input),
        source_in_same_dir: input.parent() == Some(runbook_dir.as_path()),
        chain_id,
        env,
        source: loaded.source,
        txs: loaded.txs,
        names,
        facts: None,
        notes: options.notes.clone(),
    })
}

/// What a format loader extracts.
struct Loaded {
    source: SourceKind,
    txs: Vec<RunbookTx>,
    chain_id: Option<u64>,
    names: BTreeMap<Address, String>,
    /// What the txs act on, for the heading (e.g. `chain 499`).
    subject: Option<String>,
}

fn detect(json: &Value) -> anyhow::Result<InputFormat> {
    match json {
        Value::Object(map) if map.contains_key("emergency_upgrade_board") => {
            Ok(InputFormat::EmergencyBoard)
        }
        Value::Object(map) if map.contains_key("bundles") => Ok(InputFormat::SafeManifest),
        Value::Object(map) if map.contains_key("transactions") && map.contains_key("meta") => {
            anyhow::bail!(
                "a single Safe Transaction Builder file does not record its sender; pass the \
                 manifest.json that lists it"
            )
        }
        Value::Array(items)
            if !items.is_empty()
                && items.iter().all(|item| {
                    ["from", "to", "data"]
                        .iter()
                        .all(|key| item.get(key).is_some())
                }) =>
        {
            Ok(InputFormat::Simulator)
        }
        _ => anyhow::bail!(
            "unknown transaction list format: expected an emergency-upgrade-board JSON \
             (`emergency_upgrade_board` + `transactions`), a Safe-bundle manifest.json \
             (`bundles`), or a transaction-simulator JSON array (`from`, `to`, `data` per tx)"
        ),
    }
}

// ─── emergency-upgrade-board JSON ────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EmergencyBoardFile {
    #[serde(rename = "_comment", default)]
    _comment: Option<String>,
    emergency_upgrade_board: Address,
    protocol_upgrade_handler: Address,
    owner: Address,
    #[serde(default)]
    chain_id: Option<u64>,
    transactions: Vec<EmergencyBoardTx>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EmergencyBoardTx {
    step: usize,
    label: String,
    from: Address,
    to: Address,
    data: Bytes,
    #[serde(default)]
    value: Option<Value>,
}

const APPROVE_HASH: &str = "approveHash";
const EXECUTE_EMERGENCY_UPGRADE: &str = "executeEmergencyUpgrade";

fn function_name(data: &[u8]) -> Option<&'static str> {
    known_function(data).map(|function| function.name.as_str())
}

fn load_emergency_board(json: Value) -> anyhow::Result<Loaded> {
    let file: EmergencyBoardFile =
        serde_json::from_value(json).context("emergency-upgrade-board JSON")?;
    let board = file.emergency_upgrade_board;
    let count = file.transactions.len();
    let mut txs = Vec::with_capacity(count);
    for (i, tx) in file.transactions.into_iter().enumerate() {
        let number = i + 1;
        let what = format!("tx {number} ({})", tx.label);
        anyhow::ensure!(
            tx.step == number,
            "{what} has step {}; steps must be 1..{count} in order",
            tx.step
        );
        let value = tx.value.as_ref().map(parse_value).transpose()?;
        if let Some(value) = value.filter(|value| !value.is_zero()) {
            anyhow::bail!("{what} sends value {value}; emergency-upgrade-board txs send none");
        }
        let is_last = number == count;
        if is_last {
            anyhow::ensure!(
                function_name(&tx.data) == Some(EXECUTE_EMERGENCY_UPGRADE) && tx.to == board,
                "{what}: the last tx must call {EXECUTE_EMERGENCY_UPGRADE} on the board {board:#x}"
            );
        } else {
            anyhow::ensure!(
                function_name(&tx.data) == Some(APPROVE_HASH) && tx.to != board,
                "{what}: every tx before the last must call {APPROVE_HASH} on a member Safe"
            );
            anyhow::ensure!(
                tx.from == file.owner,
                "{what} is sent by {:#x}, but only the owner {:#x} can approve on the member Safes",
                tx.from,
                file.owner
            );
        }
        txs.push(RunbookTx {
            label: tx.label,
            from: tx.from,
            to: tx.to,
            value: U256::ZERO,
            data: tx.data,
            safe_file: None,
            time_increase: None,
        });
    }
    let names = BTreeMap::from([
        (board, "Emergency Upgrade Board".to_string()),
        (
            file.protocol_upgrade_handler,
            "Protocol Upgrade Handler".to_string(),
        ),
    ]);
    Ok(Loaded {
        source: SourceKind::EmergencyBoard {
            board,
            handler: file.protocol_upgrade_handler,
            owner: file.owner,
        },
        txs,
        chain_id: file.chain_id,
        names,
        subject: None,
    })
}

// ─── Safe-bundle manifest ────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct SafeManifest {
    bundles: Vec<SafeManifestBundle>,
    /// Per-command records `write_output_if_requested` appends; their `output` objects name
    /// the addresses the command resolved.
    #[serde(default)]
    metadata: Vec<Value>,
}

/// Keys of a manifest `metadata[].output` object that name an address.
const METADATA_ADDRESS_NAMES: [(&str, &str); 4] = [
    ("admin_address", "ChainAdmin"),
    ("chain_admin_owner", "ChainAdmin owner"),
    ("chain_address", "ZK chain"),
    ("bridgehub", "Bridgehub"),
];
/// Key of a manifest `metadata[].output` object holding the L2 chain id.
const METADATA_CHAIN_ID: &str = "chain_id";

/// Names and the L2 chain id the manifest's command records carry.
fn manifest_metadata(metadata: &[Value]) -> (BTreeMap<Address, String>, Option<String>) {
    let mut names = BTreeMap::new();
    let mut chain_ids: Vec<u64> = Vec::new();
    for output in metadata.iter().filter_map(|entry| entry.get("output")) {
        for (key, name) in METADATA_ADDRESS_NAMES {
            let address = output
                .get(key)
                .and_then(Value::as_str)
                .and_then(|text| text.parse::<Address>().ok());
            if let Some(address) = address.filter(|address| !address.is_zero()) {
                names.insert(address, name.to_string());
            }
        }
        if let Some(id) = output.get(METADATA_CHAIN_ID).and_then(Value::as_u64) {
            if !chain_ids.contains(&id) {
                chain_ids.push(id);
            }
        }
    }
    let subject = match chain_ids.as_slice() {
        [id] => Some(format!("chain {id}")),
        _ => None,
    };
    (names, subject)
}

#[derive(Debug, Deserialize)]
struct SafeManifestBundle {
    file: String,
    index: u32,
    #[serde(default)]
    steps: Vec<String>,
    target: Address,
}

#[derive(Debug, Deserialize)]
struct SafeBatchFile {
    #[serde(rename = "chainId")]
    chain_id: String,
    transactions: Vec<SafeBatchTx>,
}

#[derive(Debug, Deserialize)]
struct SafeBatchTx {
    to: Address,
    #[serde(default)]
    value: Option<Value>,
    #[serde(default)]
    data: Option<Bytes>,
}

fn load_safe_manifest(json: Value, manifest: &Path, runbook_dir: &Path) -> anyhow::Result<Loaded> {
    let parsed: SafeManifest = serde_json::from_value(json).context("Safe-bundle manifest")?;
    let manifest_dir = manifest
        .parent()
        .ok_or_else(|| anyhow::anyhow!("{} has no parent", manifest.display()))?;
    let mut chain_id: Option<u64> = None;
    let mut txs = Vec::new();
    for bundle in parsed.bundles {
        anyhow::ensure!(
            Path::new(&bundle.file).file_name() == Some(bundle.file.as_ref()),
            "bundle file {:?} must be a file name next to the manifest",
            bundle.file
        );
        let path = manifest_dir.join(&bundle.file);
        let file: SafeBatchFile = serde_json::from_str(
            &fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?,
        )
        .with_context(|| format!("parse {}", path.display()))?;
        let bundle_chain: u64 = file
            .chain_id
            .parse()
            .with_context(|| format!("{}: chainId {:?}", path.display(), file.chain_id))?;
        if let Some(previous) = chain_id {
            anyhow::ensure!(
                previous == bundle_chain,
                "{} is for chain {bundle_chain}, the bundles before it for chain {previous}",
                path.display()
            );
        }
        chain_id = Some(bundle_chain);
        let link = relative_link(runbook_dir, &path);
        let steps = if bundle.steps.is_empty() {
            String::new()
        } else {
            format!("{}: ", bundle.steps.join(" + "))
        };
        for (i, tx) in file.transactions.into_iter().enumerate() {
            let data = tx.data.ok_or_else(|| {
                anyhow::anyhow!(
                    "{} tx {} has no raw data (only a contract method)",
                    path.display(),
                    i + 1
                )
            })?;
            txs.push(RunbookTx {
                label: format!("{steps}bundle {} tx {}", bundle.index, i + 1),
                from: bundle.target,
                to: tx.to,
                value: tx
                    .value
                    .as_ref()
                    .map(parse_value)
                    .transpose()?
                    .unwrap_or_default(),
                data,
                safe_file: Some(link.clone()),
                time_increase: None,
            });
        }
    }
    let (names, subject) = manifest_metadata(&parsed.metadata);
    Ok(Loaded {
        source: SourceKind::SafeBundles,
        txs,
        chain_id,
        names,
        subject,
    })
}

// ─── transaction-simulator JSON ──────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct SimulatorTx {
    description: String,
    network: String,
    from: Address,
    to: Address,
    data: Bytes,
    #[serde(default)]
    value: Option<Value>,
    #[serde(default, rename = "timeIncrease")]
    time_increase: Option<u64>,
    #[serde(default, rename = "emulateAllBatchesExecuted")]
    emulate_all_batches_executed: Option<bool>,
    #[serde(default)]
    tag: Option<String>,
}

fn load_simulator(json: Value, exclude_tags: &[String]) -> anyhow::Result<Loaded> {
    let all: Vec<SimulatorTx> =
        serde_json::from_value(json).context("transaction-simulator JSON")?;
    let mut network: Option<String> = None;
    let mut txs = Vec::new();
    for (i, tx) in all.into_iter().enumerate() {
        let tag = tx.tag.as_deref().unwrap_or_default();
        if exclude_tags.iter().any(|prefix| tag.starts_with(prefix)) {
            continue;
        }
        let what = format!("simulator tx {} ({})", i + 1, tx.description);
        anyhow::ensure!(
            tx.emulate_all_batches_executed != Some(true),
            "{what} rewrites chain storage in the simulator and cannot be sent by hand; \
             drop its tag {tag:?} with an excluded tag prefix"
        );
        match &network {
            Some(previous) => anyhow::ensure!(
                *previous == tx.network,
                "{what} is on {}, the txs before it on {previous}",
                tx.network
            ),
            None => network = Some(tx.network.clone()),
        }
        txs.push(RunbookTx {
            label: tx.description,
            from: tx.from,
            to: tx.to,
            value: tx
                .value
                .as_ref()
                .map(parse_value)
                .transpose()?
                .unwrap_or_default(),
            data: tx.data,
            safe_file: None,
            time_increase: tx.time_increase,
        });
    }
    let chain_id = network.as_deref().and_then(|network| {
        NETWORKS
            .iter()
            .find(|(_, _, simulator_name)| *simulator_name == network)
            .map(|(id, _, _)| *id)
    });
    Ok(Loaded {
        source: SourceKind::Simulator,
        txs,
        chain_id,
        names: BTreeMap::new(),
        subject: None,
    })
}

// ─── helpers ─────────────────────────────────────────────────────────────────────

/// A wei amount given as a JSON number, a decimal string or a `0x` hex string.
fn parse_value(value: &Value) -> anyhow::Result<U256> {
    match value {
        Value::Number(number) => number
            .as_u64()
            .map(U256::from)
            .ok_or_else(|| anyhow::anyhow!("value {number} is not a non-negative integer")),
        Value::String(text) => text
            .parse::<U256>()
            .with_context(|| format!("value {text:?}")),
        other => anyhow::bail!("value {other} is not a number"),
    }
}

/// `Sepolia`, `Ethereum mainnet`, or `chain <id>`.
pub(super) fn network_name(chain_id: u64) -> String {
    NETWORKS
        .iter()
        .find(|(id, _, _)| *id == chain_id)
        .map(|(_, name, _)| name.to_string())
        .unwrap_or_else(|| format!("chain {chain_id}"))
}

/// `v0.33.0-compiler` → `v0.33.0 compiler`.
fn upgrade_display(upgrade: &str) -> String {
    match upgrade.split_once('-') {
        Some((version, name)) => format!("{version} {name}"),
        None => upgrade.to_string(),
    }
}

/// `v0.33.0 compiler upgrade: stage chain 499 execution (Sepolia)`, leaving out what is unknown.
fn default_title(
    upgrade: Option<&str>,
    env: Option<&str>,
    subject: Option<&str>,
    network: &str,
) -> String {
    let upgrade = upgrade
        .map(|upgrade| format!("{} upgrade", upgrade_display(upgrade)))
        .unwrap_or_else(|| "Upgrade".to_string());
    let scope: Vec<&str> = [env, subject, Some("execution")]
        .into_iter()
        .flatten()
        .collect();
    format!("{upgrade}: {} ({network})", scope.join(" "))
}

/// `(upgrade, env)` from a path under `upgrade-envs/<upgrade>/output/<env>/`.
fn infer_upgrade_and_env(path: &Path) -> (Option<String>, Option<String>) {
    let parts: Vec<String> = path
        .parent()
        .map(|dir| {
            dir.components()
                .filter_map(|component| match component {
                    Component::Normal(part) => part.to_str().map(str::to_string),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();
    parts
        .windows(4)
        .find(|window| window[0] == "upgrade-envs" && window[2] == "output")
        .map(|window| (Some(window[1].clone()), Some(window[3].clone())))
        .unwrap_or((None, None))
}

/// A `./`- or `../`-prefixed POSIX path from `from_dir` to `target` (both canonical).
pub(super) fn relative_link(from_dir: &Path, target: &Path) -> String {
    let from: Vec<Component> = from_dir.components().collect();
    let to: Vec<Component> = target.components().collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts: Vec<String> = vec!["..".to_string(); from.len() - common];
    parts.extend(
        to[common..]
            .iter()
            .map(|component| component.as_os_str().to_string_lossy().into_owned()),
    );
    let joined = parts.join("/");
    if joined.starts_with("..") {
        joined
    } else {
        format!("./{joined}")
    }
}
