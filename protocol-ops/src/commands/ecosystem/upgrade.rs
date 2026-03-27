use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::commands::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger,
    wallets::Wallet,
};
use crate::common::paths;

#[derive(Serialize)]
struct EcosystemUpgradeOutInput {
    stage: String,
}

#[derive(Serialize)]
struct NoGovernancePrepareOutput<'a> {
    core: &'a Value,
    ecosystem: &'a Value,
    ctm: &'a Value,
    run_json: Value,
}

#[derive(Serialize)]
struct GovernanceStageOutput {
    stage: u8,
    governance_address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct EcosystemUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Ecosystem upgrade stage (currently supported: no-governance-prepare)
    #[clap(long)]
    pub ecosystem_upgrade_stage: String,
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
}

pub async fn run(args: EcosystemUpgradeArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.shared.private_key, args.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    match args.ecosystem_upgrade_stage.as_str() {
        "no-governance-prepare" => run_no_governance_prepare(&mut runner, &sender, &args),
        "governance-stage0" => run_governance_stage(&mut runner, &sender, &args, 0),
        "governance-stage1" => run_governance_stage(&mut runner, &sender, &args, 1),
        "governance-stage2" => run_governance_stage(&mut runner, &sender, &args, 2),
        other => anyhow::bail!(
            "Unsupported ecosystem upgrade stage: {} (supported: no-governance-prepare, governance-stage0, governance-stage1, governance-stage2)",
            other
        ),
    }
}

fn run_no_governance_prepare(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &EcosystemUpgradeArgs,
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
    let ctm = args.ctm_proxy_address.ok_or_else(|| {
        anyhow::anyhow!("--ctm-proxy-address is required for no-governance-prepare")
    })?;
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

    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "noGovernancePrepareWithArgs(address,address,address,address,bool,string,string,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: 1000000000000,
    });
    script_args.additional_args.extend([
        format!("{:#x}", bridgehub),
        format!("{:#x}", ctm),
        format!("{:#x}", bytecodes_supplier),
        format!("{:#x}", rollup_da_manager),
        if is_zk_sync_os {
            "true".to_string()
        } else {
            "false".to_string()
        },
        args.upgrade_input_path.clone(),
        args.upgrade_output_path.clone(),
        format!("{:#x}", governance),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender, runner.simulate);

    logger::step("Running ecosystem no-governance-prepare");
    logger::info(format!("RPC URL: {}", runner.rpc_url));

    runner
        .run(script)
        .context("Failed to execute forge script for no-governance-prepare")?;

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

    let run_json = runner
        .runs()
        .last()
        .map(|r| r.payload.clone())
        .unwrap_or_else(|| Value::Object(Default::default()));
    let out_payload = NoGovernancePrepareOutput {
        core: &core_json,
        ecosystem: &ecosystem_json,
        ctm: &ctm_json,
        run_json,
    };
    let input_env = EcosystemUpgradeOutInput {
        stage: "no-governance-prepare".to_string(),
    };
    write_output_if_requested(
        "ecosystem.upgrade",
        args.shared.out_path.as_deref(),
        runner,
        &input_env,
        &out_payload,
    )?;

    logger::success("No-governance-prepare completed");
    if let Some(ref out_path) = args.shared.out_path {
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
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &EcosystemUpgradeArgs,
    stage: u8,
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
    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "governanceExecuteCalls(bytes,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: 1000000000000,
    });
    script_args.additional_args.extend([
        format!("0x{}", encoded_calls_hex.trim_start_matches("0x")),
        format!("{:#x}", governance_addr),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender, runner.simulate);

    logger::step(format!("Running governance stage {}", stage));
    logger::info(format!("Governance address: {:#x}", governance_addr));
    logger::info(format!("RPC URL: {}", runner.rpc_url));

    runner.run(script).with_context(|| {
        format!(
            "Failed to execute forge script for governance stage {}",
            stage
        )
    })?;

    let input_env = EcosystemUpgradeOutInput {
        stage: format!("governance-stage{}", stage),
    };
    let out_payload = GovernanceStageOutput {
        stage,
        governance_address: format!("{:#x}", governance_addr),
    };
    write_output_if_requested(
        "ecosystem.upgrade",
        args.shared.out_path.as_deref(),
        runner,
        &input_env,
        &out_payload,
    )?;

    logger::success(format!("Governance stage {} completed", stage));
    if let Some(ref out_path) = args.shared.out_path {
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
