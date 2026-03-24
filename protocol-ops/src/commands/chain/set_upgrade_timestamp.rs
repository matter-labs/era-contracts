use std::fs;
use std::path::PathBuf;
use std::process::Command;

use anyhow::Context;
use clap::Parser;
use ethers::types::H256;
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::common::logger;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetUpgradeTimestampArgs {
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    /// Governor/admin private key used for scheduling upgrade
    #[clap(long)]
    pub private_key: H256,
    /// Chain admin address
    #[clap(long)]
    pub admin_address: String,
    /// New packed protocol version (uint256)
    #[clap(long)]
    pub new_protocol_version: String,
    /// Upgrade timestamp (unix seconds)
    #[clap(long)]
    pub upgrade_timestamp: String,
    /// Simulate: only write transaction(s) to --out, do not send
    #[clap(long, default_value_t = false)]
    pub simulate: bool,
    /// Write transactions JSON to file (for simulate: use with execute_transactions)
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,
}

pub async fn run(args: ChainSetUpgradeTimestampArgs, shell: &Shell) -> anyhow::Result<()> {
    let _ = shell;

    logger::step("Setting chain upgrade timestamp via AdminFunctions.s.sol");
    logger::info(format!("Admin address: {}", args.admin_address));
    logger::info(format!(
        "New protocol version: {}",
        args.new_protocol_version
    ));
    logger::info(format!("Upgrade timestamp: {}", args.upgrade_timestamp));
    logger::info(format!("RPC URL: {}", args.l1_rpc_url));

    let calldata_output = Command::new("cast")
        .args([
            "calldata",
            "setUpgradeTimestamp(uint256,uint256)",
            &args.new_protocol_version,
            &args.upgrade_timestamp,
        ])
        .output()
        .context("Failed to run cast calldata for set-upgrade-timestamp")?;
    if !calldata_output.status.success() {
        anyhow::bail!(
            "cast calldata failed:\nSTDERR:\n{}",
            String::from_utf8_lossy(&calldata_output.stderr)
        );
    }
    let data = String::from_utf8_lossy(&calldata_output.stdout)
        .trim()
        .to_string();
    let data = if data.starts_with("0x") {
        data
    } else {
        format!("0x{}", data)
    };

    let transactions = vec![json!({
        "to": args.admin_address,
        "data": data,
        "value": "0",
    })];

    if args.simulate {
        if let Some(ref out_path) = args.out {
            let out_json = json!({
                "command": "chain.set-upgrade-timestamp",
                "transactions": transactions,
            });
            fs::write(out_path, serde_json::to_string_pretty(&out_json)?)
                .context("Failed to write set-upgrade-timestamp out file")?;
            logger::info(format!("Output written to: {}", out_path.display()));
            logger::success("Set upgrade timestamp (simulate) completed");
            logger::outro(format!(
                "Set upgrade timestamp simulated. Output written to: {}",
                out_path.display()
            ));
        } else {
            logger::success("Set upgrade timestamp (simulate) completed");
            logger::outro("Set upgrade timestamp simulated. Use --out to write transactions for execute_transactions.");
        }
        return Ok(());
    }

    logger::info("Broadcast: true");
    let mut cmd = Command::new("cast");
    cmd.arg("send")
        .arg(&args.admin_address)
        .arg("setUpgradeTimestamp(uint256,uint256)")
        .arg(&args.new_protocol_version)
        .arg(&args.upgrade_timestamp)
        .arg("--rpc-url")
        .arg(&args.l1_rpc_url)
        .arg("--private-key")
        .arg(format!("{:#x}", args.private_key))
        .arg("--legacy");

    let output = cmd
        .output()
        .context("Failed to execute cast send for set-upgrade-timestamp")?;
    if !output.status.success() {
        anyhow::bail!(
            "cast send failed:\nSTDOUT:\n{}\nSTDERR:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    logger::success("Set upgrade timestamp completed");
    logger::outro("Set upgrade timestamp completed.");
    Ok(())
}
