use std::collections::HashSet;
use std::sync::OnceLock;

use serde_json::{json, Value};

use super::runner::ForgeRunner;
use crate::common::{logger, paths};

/// Source-path prefix used to identify forge "script libraries" that exist
/// only to support the deploy-scripts during a forge run. They have no
/// production role; when `forge script --broadcast` runs against a real chain
/// it CREATE2-deploys them anyway because their `public` library functions
/// compile as `external`. We strip those CREATE2 deploys from the Safe-bundle
/// output here so they don't pollute the upgrade Safe bundle (and ultimately
/// real-chain state).
const SCRIPT_LIB_SOURCE_PREFIX: &str = "deploy-scripts/";

/// Set of `contractName`s whose compilation target source-path lives under
/// `SCRIPT_LIB_SOURCE_PREFIX`. Built lazily by walking `<l1-contracts>/out/*.sol/*.json`
/// on first use, cached for the rest of the process. Returns an empty set if
/// the artifacts dir can't be read (no filtering happens; safe degradation).
fn script_only_library_names() -> &'static HashSet<String> {
    static SET: OnceLock<HashSet<String>> = OnceLock::new();
    SET.get_or_init(|| {
        let out_dir = paths::contracts_root().join("l1-contracts").join("out");
        let mut names = HashSet::new();
        let walker = match std::fs::read_dir(&out_dir) {
            Ok(it) => it,
            Err(_) => return names,
        };
        for entry in walker.flatten() {
            let sol_dir = entry.path();
            let Ok(inner) = std::fs::read_dir(&sol_dir) else {
                continue;
            };
            for art in inner.flatten() {
                let p = art.path();
                if p.extension().and_then(|s| s.to_str()) != Some("json") {
                    continue;
                }
                let Ok(s) = std::fs::read_to_string(&p) else {
                    continue;
                };
                let Ok(meta) = serde_json::from_str::<Value>(&s) else {
                    continue;
                };
                let Some(targets) = meta
                    .get("metadata")
                    .and_then(|m| m.get("settings"))
                    .and_then(|s| s.get("compilationTarget"))
                    .and_then(|t| t.as_object())
                else {
                    continue;
                };
                for (src_path, contract_name) in targets {
                    if src_path.starts_with(SCRIPT_LIB_SOURCE_PREFIX) {
                        if let Some(n) = contract_name.as_str() {
                            names.insert(n.to_string());
                        }
                    }
                }
            }
        }
        names
    })
}

/// A contiguous run of txs that share a single `from` ("target") — the unit
/// that can be executed as one Safe Transaction Builder batch.
#[derive(Debug, Clone)]
pub struct SafeBundle {
    /// Address expected to execute the batch (the Safe, or an EOA).
    pub target: String,
    /// Protocol-ops command names that contributed txs to this bundle, in order
    /// of first appearance. Deduplicated.
    pub steps: Vec<String>,
    /// The txs in order, each still carrying `from` / `to` / `data` / `value` / `step`.
    pub txs: Vec<Value>,
}

/// Cast-ready transactions from every recorded forge run, in order. Each tx
/// is tagged with `step = <command>` so downstream tooling can attribute it.
pub fn all_runs_cast_transactions(runner: &ForgeRunner, step: &str) -> anyhow::Result<Vec<Value>> {
    let mut out = Vec::new();
    for r in runner.runs() {
        out.extend(run_payload_to_cast_transactions(&r.payload, step)?);
    }
    Ok(out)
}

/// Split this runner's txs into per-target Safe bundles.
///
/// Each bundle is a contiguous run of txs that share a `from` ("target").
/// Returns one `SafeBundle` per distinct signer-contiguous run — phase
/// commands that switch signers mid-runner produce N bundles, single-signer
/// commands produce 1.
pub fn split_into_bundles(runner: &ForgeRunner, step: &str) -> anyhow::Result<Vec<SafeBundle>> {
    let current = all_runs_cast_transactions(runner, step)?;
    if current.is_empty() {
        return Ok(Vec::new());
    }

    let mut bundles: Vec<SafeBundle> = Vec::new();
    for tx in current {
        let target = tx_from(&tx);
        let tx_step = tx_step(&tx);
        match bundles.last_mut() {
            Some(b) if b.target.eq_ignore_ascii_case(&target) => {
                push_unique(&mut b.steps, &tx_step);
                b.txs.push(tx);
            }
            _ => bundles.push(SafeBundle {
                target,
                steps: step_vec(&tx_step),
                txs: vec![tx],
            }),
        }
    }

    Ok(bundles)
}

fn tx_from(tx: &Value) -> String {
    tx.get("from")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

fn tx_step(tx: &Value) -> String {
    tx.get("step")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

fn push_unique(vec: &mut Vec<String>, s: &str) {
    if !s.is_empty() && !vec.iter().any(|x| x == s) {
        vec.push(s.to_string());
    }
}

fn step_vec(s: &str) -> Vec<String> {
    if s.is_empty() {
        Vec::new()
    } else {
        vec![s.to_string()]
    }
}

/// Build cast-ready transaction list from a forge run payload (broadcast JSON).
/// Each item has "step", "from", "to", "data", "value" (normalized for cast
/// replay). `from` is required — replay uses it as the per-tx sender.
pub(crate) fn run_payload_to_cast_transactions(
    payload: &Value,
    step: &str,
) -> anyhow::Result<Vec<Value>> {
    let txs = match payload.get("transactions").and_then(|t| t.as_array()) {
        Some(a) => a,
        None => return Ok(vec![]),
    };
    let mut out = Vec::with_capacity(txs.len());
    let script_libs = script_only_library_names();
    for (idx, tx) in txs.iter().enumerate() {
        // Drop forge-emitted CREATE2 deploys for script-only libraries (any
        // `public` library function under `deploy-scripts/`). They have no
        // production role and shouldn't end up in the Safe bundle. See
        // `SCRIPT_LIB_SOURCE_PREFIX`.
        let tx_type = tx.get("transactionType").and_then(|v| v.as_str()).unwrap_or("");
        if tx_type == "CREATE2" || tx_type == "CREATE" {
            if let Some(name) = tx.get("contractName").and_then(|v| v.as_str()) {
                if script_libs.contains(name) {
                    let addr = tx
                        .get("contractAddress")
                        .and_then(|v| v.as_str())
                        .unwrap_or("?");
                    logger::info(format!(
                        "Skipping CREATE2 of script-only library {name} ({addr}) in Safe bundle"
                    ));
                    continue;
                }
            }
        }
        let params = tx.get("transaction").unwrap_or(tx);
        let to = match params.get("to").and_then(|v| v.as_str()) {
            Some(s) => s,
            None => continue,
        };
        let from = params.get("from").and_then(|v| v.as_str()).ok_or_else(|| {
            anyhow::anyhow!(
                "forge broadcast tx #{idx} missing required `from` field — \
                     protocol-ops output requires a per-tx sender for replay"
            )
        })?;
        let data = params
            .get("data")
            .or_else(|| params.get("input"))
            .and_then(|v| v.as_str())
            .unwrap_or("0x");
        let value_raw = params
            .get("value")
            .and_then(|v| {
                v.get("hex")
                    .and_then(|h| h.as_str())
                    .map(String::from)
                    .or_else(|| v.as_str().map(String::from))
                    .or_else(|| v.as_u64().map(|n| n.to_string()))
            })
            .unwrap_or_else(|| "0".to_string());
        let value = normalize_cast_value(&value_raw);
        out.push(json!({
            "step": step,
            "from": from,
            "to": to,
            "data": data,
            "value": value,
        }));
    }
    Ok(out)
}

fn normalize_cast_value(raw: &str) -> String {
    let s = raw.trim();
    if s.is_empty() || s == "0" || s == "0x0" || s == "0x" {
        return "0".to_string();
    }
    if let Some(hex) = s.strip_prefix("0x") {
        if hex.chars().all(|c| c.is_ascii_hexdigit()) {
            let hex = hex.trim_start_matches('0');
            if hex.is_empty() {
                return "0".to_string();
            }
            return format!("0x{}", hex);
        }
    }
    s.to_string()
}
