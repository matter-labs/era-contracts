use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Context;
use clap::Parser;
use serde_json::{Map, Value};

use crate::common::{logger, paths};

#[derive(Debug, Clone, Parser)]
pub struct DevExecuteTransactionsArgs {
    /// Path to protocol-ops --out JSON file
    #[clap(long)]
    pub out: PathBuf,
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    /// Private key used to broadcast transactions
    #[clap(long)]
    pub private_key: String,
}

fn resolve_l1_contracts_path(repo_root: &Path) -> anyhow::Result<PathBuf> {
    let direct = repo_root.join("l1-contracts");
    if direct.exists() {
        return Ok(direct);
    }
    let nested = repo_root.join("contracts").join("l1-contracts");
    if nested.exists() {
        return Ok(nested);
    }
    anyhow::bail!(
        "Could not locate l1-contracts under {} (checked l1-contracts and contracts/l1-contracts)",
        repo_root.display()
    )
}

pub async fn run(args: DevExecuteTransactionsArgs) -> anyhow::Result<()> {
    logger::step("Execute simulated transactions from protocol-ops out file");

    let content = fs::read_to_string(&args.out)
        .with_context(|| format!("Failed to read out file: {}", args.out.display()))?;
    let root: Value = serde_json::from_str(&content).context("Failed to parse out file as JSON")?;
    let txs = root
        .get("transactions")
        .and_then(|t| t.as_array())
        .ok_or_else(|| anyhow::anyhow!("Out file missing or invalid .transactions array"))?;
    let count = txs.len();
    logger::info(format!("Extracted {} transactions", count));

    let contracts_root = paths::contracts_root();
    let l1_contracts = resolve_l1_contracts_path(&contracts_root)?;
    let script_input_path = l1_contracts.join("script-out/execute_protocol_ops_input.json");
    if let Some(parent) = script_input_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create {}", parent.display()))?;
    }

    let mut only = Map::new();
    only.insert("transactions".to_string(), Value::Array(txs.clone()));
    let small_json = serde_json::to_string_pretty(&Value::Object(only))
        .context("Failed to serialize transactions JSON")?;
    fs::write(&script_input_path, small_json)
        .with_context(|| format!("Failed to write {}", script_input_path.display()))?;
    logger::info(format!(
        "Wrote transactions to {}",
        script_input_path.display()
    ));

    let path_str = script_input_path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Path contains invalid UTF-8"))?;

    if !l1_contracts
        .join("deploy-scripts/ExecuteProtocolOpsOut.s.sol")
        .exists()
    {
        anyhow::bail!(
            "ExecuteProtocolOpsOut.s.sol not found under {}",
            l1_contracts.display()
        );
    }

    let output = Command::new("forge")
        .args([
            "script",
            "deploy-scripts/ExecuteProtocolOpsOut.s.sol",
            "--sig",
            "run(string,uint256)",
            path_str,
            &count.to_string(),
            "--private-key",
            &args.private_key,
            "--rpc-url",
            &args.l1_rpc_url,
            "--broadcast",
            "--legacy",
        ])
        .current_dir(&l1_contracts)
        .output()
        .with_context(|| "Failed to run forge script ExecuteProtocolOpsOut")?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "ExecuteProtocolOpsOut failed\nSTDOUT:\n{}\nSTDERR:\n{}",
            stdout,
            stderr
        );
    }

    logger::success("Execute simulated transactions completed");
    Ok(())
}
