use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Context;
use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::common::logger;
use crate::utils::paths;

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
    /// CREATE2 factory salt (required for no-governance-prepare)
    #[clap(long)]
    pub create2_factory_salt: Option<H256>,
    /// Upgrade input path relative to l1-contracts root (for no-governance-prepare)
    #[clap(long, default_value = "/upgrade-envs/v0.31.0-interopB/local.toml")]
    pub upgrade_input_path: String,
    /// Upgrade output path relative to l1-contracts root (for no-governance-prepare)
    #[clap(long, default_value = "/script-out/v31-upgrade-ecosystem.toml")]
    pub upgrade_output_path: String,
    /// Skip broadcasting transactions
    #[clap(long, default_value_t = false)]
    pub skip_broadcast: bool,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: crate::common::forge::ForgeArgs,
}

pub async fn run(args: EcosystemUpgradeArgs, shell: &Shell) -> anyhow::Result<()> {
    let _ = shell;
    match args.ecosystem_upgrade_stage.as_str() {
        "no-governance-prepare" => run_no_governance_prepare(&args),
        "governance-stage0" => run_governance_stage(&args, 0),
        "governance-stage1" => run_governance_stage(&args, 1),
        "governance-stage2" => run_governance_stage(&args, 2),
        other => anyhow::bail!(
            "Unsupported ecosystem upgrade stage: {} (supported: no-governance-prepare, governance-stage0, governance-stage1, governance-stage2)",
            other
        ),
    }
}

fn run_no_governance_prepare(args: &EcosystemUpgradeArgs) -> anyhow::Result<()> {
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
    let create2_salt = args.create2_factory_salt.ok_or_else(|| {
        anyhow::anyhow!("--create2-factory-salt is required for no-governance-prepare")
    })?;
    let rollup_da_manager = args.rollup_da_manager_address.unwrap_or_default();
    let governance = args.governance_address.unwrap_or_default();

    let upgrade_input = contracts_path.join(args.upgrade_input_path.trim_start_matches('/'));
    if !upgrade_input.exists() {
        anyhow::bail!("Upgrade input file not found: {}", upgrade_input.display());
    }

    let mut cmd = Command::new("forge");
    cmd.arg("script")
        .arg(script_path)
        .arg("--sig")
        .arg("noGovernancePrepareWithArgs(address,address,address,address,bool,bytes32,string,string,address)")
        .arg(format!("{:#x}", bridgehub))
        .arg(format!("{:#x}", ctm))
        .arg(format!("{:#x}", bytecodes_supplier))
        .arg(format!("{:#x}", rollup_da_manager))
        .arg(if is_zk_sync_os { "true" } else { "false" })
        .arg(format!("{:#x}", create2_salt))
        .arg(args.upgrade_input_path.as_str())
        .arg(args.upgrade_output_path.as_str())
        .arg(format!("{:#x}", governance))
        .arg("--rpc-url")
        .arg(&args.l1_rpc_url)
        .arg("--private-key")
        .arg(format!("{:#x}", args.private_key))
        .arg("--ffi")
        .arg("--gas-limit")
        .arg("1000000000000")
        .current_dir(&contracts_path);

    if !args.skip_broadcast {
        cmd.arg("--broadcast");
    }

    logger::step("Running ecosystem no-governance-prepare");
    logger::info(format!("RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("Broadcast: {}", !args.skip_broadcast));

    let output = cmd
        .output()
        .context("Failed to execute forge script for no-governance-prepare")?;
    if !output.status.success() {
        anyhow::bail!(
            "Forge script failed:\nSTDOUT:\n{}\nSTDERR:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    logger::success("No-governance-prepare completed");
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

fn run_governance_stage(args: &EcosystemUpgradeArgs, stage: u8) -> anyhow::Result<()> {
    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let upgrade_output_path = contracts_path.join("script-out/v31-upgrade-ecosystem.toml");
    let toml_content = std::fs::read_to_string(&upgrade_output_path).with_context(|| {
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
    let mut cmd = Command::new("forge");
    cmd.arg("script")
        .arg(script_path)
        .arg("--sig")
        .arg("governanceExecuteCalls(bytes,address)")
        .arg(format!("0x{}", encoded_calls_hex.trim_start_matches("0x")))
        .arg(format!("{:#x}", governance_addr))
        .arg("--rpc-url")
        .arg(&args.l1_rpc_url)
        .arg("--private-key")
        .arg(format!("{:#x}", args.private_key))
        .arg("--ffi")
        .arg("--gas-limit")
        .arg("1000000000000")
        .current_dir(&contracts_path);

    if !args.skip_broadcast {
        cmd.arg("--broadcast");
    }

    logger::step(format!("Running governance stage {}", stage));
    logger::info(format!("Governance address: {:#x}", governance_addr));
    logger::info(format!("RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("Broadcast: {}", !args.skip_broadcast));

    let output = cmd
        .output()
        .context("Failed to execute forge script for governance stage")?;
    if !output.status.success() {
        anyhow::bail!(
            "Forge script failed:\nSTDOUT:\n{}\nSTDERR:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    logger::success(format!("Governance stage {} completed", stage));
    Ok(())
}
