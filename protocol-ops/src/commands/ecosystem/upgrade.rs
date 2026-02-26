use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use xshell::Shell;

use crate::common::forge::{resolve_execution, Forge, ForgeRunner, ForgeScriptArg};
use crate::common::logger;
use crate::utils::paths;

/// Build cast-ready transaction list from a forge run payload (broadcast JSON).
/// Each item has "to", "data", "value" (normalized for cast).
fn run_payload_to_cast_transactions(payload: &Value) -> Vec<Value> {
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
        let value_raw = params.get("value").and_then(|v| {
            v.get("hex")
                .and_then(|h| h.as_str())
                .map(String::from)
                .or_else(|| v.as_str().map(String::from))
                .or_else(|| v.as_u64().map(|n| n.to_string()))
        }).unwrap_or_else(|| "0".to_string());
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

/// Build structured --out JSON for no-governance-prepare (like init's build_output).
fn build_output_no_governance_prepare(
    runner: &ForgeRunner,
    core_json: &Value,
    ecosystem_json: &Value,
    ctm_json: &Value,
) -> Value {
    let runs: Vec<_> = runner
        .runs()
        .iter()
        .map(|r| json!({ "script": r.script.display().to_string(), "run": r.payload }))
        .collect();
    let transactions = runner
        .runs()
        .first()
        .map(|r| run_payload_to_cast_transactions(&r.payload))
        .unwrap_or_default();
    let run_json = runner
        .runs()
        .last()
        .map(|r| r.payload.clone())
        .unwrap_or(Value::Object(Default::default()));
    json!({
        "command": "ecosystem.upgrade",
        "stage": "no-governance-prepare",
        "runs": runs,
        "transactions": transactions,
        "output": {
            "core": core_json,
            "ecosystem": ecosystem_json,
            "ctm": ctm_json,
            "run_json": run_json,
        },
    })
}

/// Build structured --out JSON for governance-stage* (like init's build_output).
fn build_output_governance_stage(
    runner: &ForgeRunner,
    stage: u8,
    governance_addr: Address,
) -> Value {
    let runs: Vec<_> = runner
        .runs()
        .iter()
        .map(|r| json!({ "script": r.script.display().to_string(), "run": r.payload }))
        .collect();
    let transactions = runner
        .runs()
        .first()
        .map(|r| run_payload_to_cast_transactions(&r.payload))
        .unwrap_or_default();
    let stage_name = format!("governance-stage{}", stage);
    json!({
        "command": "ecosystem.upgrade",
        "stage": stage_name,
        "runs": runs,
        "transactions": transactions,
        "output": {
            "stage": stage,
            "governance_address": format!("{:#x}", governance_addr),
        },
    })
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct EcosystemUpgradeArgs {
    /// Ecosystem upgrade stage (currently supported: no-governance-prepare)
    #[clap(long)]
    pub ecosystem_upgrade_stage: String,
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    /// Deployer private key
    #[clap(long)]
    pub private_key: H256,
    /// Governance address (required for governance-stage* stages)
    #[clap(long)]
    pub governance_address: Option<Address>,
    /// Bridgehub proxy address (required for no-governance-prepare)
    #[clap(long)]
    pub bridgehub_proxy_address: Option<Address>,
    /// CTM proxy address (required for no-governance-prepare)
    #[clap(long)]
    pub ctm_proxy_address: Option<Address>,
    /// Bytecodes supplier address (required for no-governance-prepare)
    #[clap(long)]
    pub bytecodes_supplier_address: Option<Address>,
    /// Rollup DA manager address (optional for no-governance-prepare)
    #[clap(long)]
    pub rollup_da_manager_address: Option<Address>,
    /// Whether target chain is ZKsync OS (required for no-governance-prepare)
    #[clap(long)]
    pub is_zk_sync_os: Option<bool>,
    /// Upgrade input path relative to l1-contracts root (for no-governance-prepare)
    #[clap(long, default_value = "/upgrade-envs/v0.31.0-interopB/local.toml")]
    pub upgrade_input_path: String,
    /// Upgrade output path relative to l1-contracts root (for no-governance-prepare)
    #[clap(long, default_value = "/script-out/v31-upgrade-ecosystem.toml")]
    pub upgrade_output_path: String,
    /// Path to read ecosystem upgrade output (for governance-stage*). If unset, uses script-out/v31-upgrade-ecosystem.toml under l1-contracts.
    #[clap(long)]
    pub ecosystem_output_path: Option<PathBuf>,
    /// Simulate against anvil fork (no on-chain changes)
    #[clap(long, default_value_t = false)]
    pub simulate: bool,
    /// Write full JSON output (runs with transactions) to file; implies broadcast when set
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: crate::common::forge::ForgeArgs,
}

pub async fn run(args: EcosystemUpgradeArgs, shell: &Shell) -> anyhow::Result<()> {
    if args.simulate {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
    }
    let exec = if args.simulate {
        Some(resolve_execution(
            Some(args.private_key),
            None,
            true,
            &args.l1_rpc_url,
        )?)
    } else {
        None
    };
    let (effective_rpc, use_sender, sender_or_pk) = match &exec {
        Some((_, sender, mode)) => (
            mode.rpc_url(&args.l1_rpc_url).to_string(),
            true,
            format!("{:#x}", sender),
        ),
        None => (
            args.l1_rpc_url.clone(),
            false,
            format!("{:#x}", args.private_key),
        ),
    };
    let result = match args.ecosystem_upgrade_stage.as_str() {
        "no-governance-prepare" => run_no_governance_prepare(shell, &args, &effective_rpc, use_sender, &sender_or_pk),
        "governance-stage0" => run_governance_stage(shell, &args, 0, &effective_rpc, use_sender, &sender_or_pk),
        "governance-stage1" => run_governance_stage(shell, &args, 1, &effective_rpc, use_sender, &sender_or_pk),
        "governance-stage2" => run_governance_stage(shell, &args, 2, &effective_rpc, use_sender, &sender_or_pk),
        other => anyhow::bail!(
            "Unsupported ecosystem upgrade stage: {} (supported: no-governance-prepare, governance-stage0, governance-stage1, governance-stage2)",
            other
        ),
    };
    drop(exec);
    result
}

fn run_no_governance_prepare(
    shell: &Shell,
    args: &EcosystemUpgradeArgs,
    effective_rpc: &str,
    use_sender: bool,
    sender_or_pk: &str,
) -> anyhow::Result<()> {
    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let script_path = "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
    let script_full_path = contracts_path.join(script_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }

    let bridgehub = args.bridgehub_proxy_address.ok_or_else(|| {
        anyhow::anyhow!("--bridgehub-proxy-address is required for no-governance-prepare")
    })?;
    let ctm = args
        .ctm_proxy_address
        .ok_or_else(|| anyhow::anyhow!("--ctm-proxy-address is required for no-governance-prepare"))?;
    let bytecodes_supplier = args.bytecodes_supplier_address.ok_or_else(|| {
        anyhow::anyhow!("--bytecodes-supplier-address is required for no-governance-prepare")
    })?;
    let is_zk_sync_os = args
        .is_zk_sync_os
        .ok_or_else(|| anyhow::anyhow!("--is-zk-sync-os is required for no-governance-prepare"))?;
    let rollup_da_manager = args.rollup_da_manager_address.unwrap_or_default();
    let governance = args.governance_address.unwrap_or_default();

    let upgrade_input = contracts_path.join(args.upgrade_input_path.trim_start_matches('/'));
    if !upgrade_input.exists() {
        anyhow::bail!("Upgrade input file not found: {}", upgrade_input.display());
    }

    // Remove existing script outputs so we only read fresh results from this run.
    let script_out = contracts_path.join("script-out");
    let _ = fs::remove_file(script_out.join("v31-upgrade-core.toml"));
    let _ = fs::remove_file(script_out.join("v31-upgrade-ecosystem.toml"));
    let _ = fs::remove_file(script_out.join("v31-upgrade-ctm.toml"));

    let mut script_args = args.forge_args.script.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "noGovernancePrepareWithArgs(address,address,address,address,bool,string,string,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: effective_rpc.to_string(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: 1000000000000,
    });
    if use_sender {
        script_args.add_arg(ForgeScriptArg::Sender {
            address: sender_or_pk.to_string(),
        });
        script_args.add_arg(ForgeScriptArg::Unlocked);
    } else {
        script_args.add_arg(ForgeScriptArg::PrivateKey {
            private_key: sender_or_pk.to_string(),
        });
    }
    script_args.additional_args.extend([
        format!("{:#x}", bridgehub),
        format!("{:#x}", ctm),
        format!("{:#x}", bytecodes_supplier),
        format!("{:#x}", rollup_da_manager),
        if is_zk_sync_os { "true".to_string() } else { "false".to_string() },
        args.upgrade_input_path.clone(),
        args.upgrade_output_path.clone(),
        format!("{:#x}", governance),
    ]);

    let forge = Forge::new(&contracts_path);
    let script = forge.script(Path::new(script_path), script_args);
    let mut runner = ForgeRunner::new();

    logger::step("Running ecosystem no-governance-prepare");
    logger::info(format!("RPC URL: {}", effective_rpc));

    runner.run(shell, script).context("Failed to execute forge script for no-governance-prepare")?;

    // Read TOML files written by the script; parse to JSON.
    let script_out = contracts_path.join("script-out");
    let core_path = script_out.join("v31-upgrade-core.toml");
    let ecosystem_path = script_out.join("v31-upgrade-ecosystem.toml");
    let ctm_path = script_out.join("v31-upgrade-ctm.toml");

    let core_toml = fs::read_to_string(&core_path)
        .with_context(|| format!("Failed to read {}", core_path.display()))?;
    let ecosystem_toml = fs::read_to_string(&ecosystem_path)
        .with_context(|| format!("Failed to read {}", ecosystem_path.display()))?;
    let ctm_toml = fs::read_to_string(&ctm_path)
        .with_context(|| format!("Failed to read {}", ctm_path.display()))?;

    let core_json: serde_json::Value = toml::from_str::<toml::Value>(&core_toml)
        .context("Failed to parse core TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{}", e)))?;
    let ecosystem_json: serde_json::Value = toml::from_str::<toml::Value>(&ecosystem_toml)
        .context("Failed to parse ecosystem TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{}", e)))?;
    let ctm_json: serde_json::Value = toml::from_str::<toml::Value>(&ctm_toml)
        .context("Failed to parse CTM TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{}", e)))?;

    if let Some(ref out_path) = args.out {
        let out_json = build_output_no_governance_prepare(&runner, &core_json, &ecosystem_json, &ctm_json);
        let out_str = serde_json::to_string_pretty(&out_json)?;
        fs::write(out_path, out_str)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    logger::success("No-governance-prepare completed");
    if let Some(ref out_path) = args.out {
        logger::outro(format!(
            "No-governance-prepare complete. Output written to: {}",
            out_path.display()
        ));
    } else {
        logger::outro("No-governance-prepare complete.");
    }
    Ok(())
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
        "Could not resolve l1-contracts path under {} (tried {} and {})",
        repo_root.display(),
        direct.display(),
        nested.display()
    )
}

#[derive(Debug, Deserialize)]
struct GovernanceCalls {
    stage0_calls: String,
    stage1_calls: String,
    stage2_calls: String,
}

#[derive(Debug, Deserialize)]
struct EcosystemUpgradeOutput {
    governance_calls: GovernanceCalls,
}

fn run_governance_stage(
    shell: &Shell,
    args: &EcosystemUpgradeArgs,
    stage: u8,
    effective_rpc: &str,
    use_sender: bool,
    sender_or_pk: &str,
) -> anyhow::Result<()> {
    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let default_path = contracts_path.join("script-out/v31-upgrade-ecosystem.toml");
    let upgrade_output_path = args
        .ecosystem_output_path
        .as_deref()
        .unwrap_or(&default_path);
    let toml_content = std::fs::read_to_string(upgrade_output_path).with_context(|| {
        format!(
            "Failed to read upgrade output file: {}",
            upgrade_output_path.display()
        )
    })?;

    let upgrade_output: EcosystemUpgradeOutput =
        toml::from_str(&toml_content).context("Failed to parse upgrade output TOML")?;

    let encoded_calls_hex = match stage {
        0 => &upgrade_output.governance_calls.stage0_calls,
        1 => &upgrade_output.governance_calls.stage1_calls,
        2 => &upgrade_output.governance_calls.stage2_calls,
        _ => anyhow::bail!("Invalid stage: {}. Must be 0, 1, or 2", stage),
    };

    let governance_addr = args.governance_address.ok_or_else(|| {
        anyhow::anyhow!(
            "--governance-address is required for governance-stage{}",
            stage
        )
    })?;

    let script_path = "deploy-scripts/AdminFunctions.s.sol";
    let mut script_args = args.forge_args.script.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "governanceExecuteCalls(bytes,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: effective_rpc.to_string(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: 1000000000000,
    });
    if use_sender {
        script_args.add_arg(ForgeScriptArg::Sender {
            address: sender_or_pk.to_string(),
        });
        script_args.add_arg(ForgeScriptArg::Unlocked);
    } else {
        script_args.add_arg(ForgeScriptArg::PrivateKey {
            private_key: sender_or_pk.to_string(),
        });
    }
    script_args.additional_args.extend([
        format!("0x{}", encoded_calls_hex.trim_start_matches("0x")),
        format!("{:#x}", governance_addr),
    ]);

    let forge = Forge::new(&contracts_path);
    let script = forge.script(Path::new(script_path), script_args);
    let mut runner = ForgeRunner::new();

    logger::step(format!("Running governance stage {}", stage));
    logger::info(format!("Governance address: {:#x}", governance_addr));
    logger::info(format!("RPC URL: {}", effective_rpc));

    runner.run(shell, script).with_context(|| {
        format!("Failed to execute forge script for governance stage {}", stage)
    })?;

    if let Some(ref out_path) = args.out {
        let out_json = build_output_governance_stage(&runner, stage, governance_addr);
        let out_str = serde_json::to_string_pretty(&out_json)?;
        fs::write(out_path, out_str)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    logger::success(format!("Governance stage {} completed", stage));
    if let Some(ref out_path) = args.out {
        logger::outro(format!(
            "Governance stage {} complete. Output written to: {}",
            stage,
            out_path.display()
        ));
    } else {
        logger::outro(format!("Governance stage {} complete.", stage));
    }
    Ok(())
}
