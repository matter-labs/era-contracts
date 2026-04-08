use serde_json::{json, Value};

use super::runner::ForgeRunner;

/// Cast-ready transactions from every recorded forge run, in order.
pub fn all_runs_cast_transactions(runner: &ForgeRunner) -> Vec<Value> {
    runner
        .runs()
        .iter()
        .flat_map(|r| run_payload_to_cast_transactions(&r.payload))
        .collect()
}

/// Build cast-ready transaction list from a forge run payload (broadcast JSON).
/// Each item has "to", "data", "value" (normalized for cast / ExecuteProtocolOpsOut).
pub(crate) fn run_payload_to_cast_transactions(payload: &Value) -> Vec<Value> {
    let txs = match payload.get("transactions").and_then(|t| t.as_array()) {
        Some(a) => a,
        None => return vec![],
    };
    let mut out = Vec::with_capacity(txs.len());
    for tx in txs {
        let params = tx.get("transaction").unwrap_or(tx);
        let to = match params.get("to").and_then(|v| v.as_str()) {
            Some(s) => s,
            None => continue,
        };
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
        out.push(json!({ "to": to, "data": data, "value": value }));
    }
    out
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
