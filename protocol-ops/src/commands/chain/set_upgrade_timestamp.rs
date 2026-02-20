use std::process::Command;

use anyhow::Context;
use clap::Parser;
use ethers::types::H256;
use serde::{Deserialize, Serialize};
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
    /// Skip broadcasting transactions
    #[clap(long, default_value_t = false)]
    pub skip_broadcast: bool,
}

pub async fn run(args: ChainSetUpgradeTimestampArgs, shell: &Shell) -> anyhow::Result<()> {
    let _ = shell;
    if args.skip_broadcast {
        logger::warn("skip-broadcast is set; no transaction will be sent");
        logger::success("Set upgrade timestamp skipped");
        return Ok(());
    }

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

    logger::step("Setting chain upgrade timestamp via AdminFunctions.s.sol");
    logger::info(format!("Admin address: {}", args.admin_address));
    logger::info(format!(
        "New protocol version: {}",
        args.new_protocol_version
    ));
    logger::info(format!("Upgrade timestamp: {}", args.upgrade_timestamp));
    logger::info(format!("RPC URL: {}", args.l1_rpc_url));
    logger::info("Broadcast: true");

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
    Ok(())
}
