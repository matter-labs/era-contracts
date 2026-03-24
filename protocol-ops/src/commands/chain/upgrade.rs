use std::path::{Path, PathBuf};
use std::process::Command;

use crate::common::forge::ForgeArgs;
use crate::common::logger;
use crate::utils::paths;
use anyhow::Context;
use clap::Parser;
use ethers::types::H256;
use serde::{Deserialize, Serialize};
use xshell::Shell;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    /// Governor private key
    #[clap(long)]
    pub private_key: H256,
    /// Chain diamond proxy address
    #[clap(long)]
    pub chain_address: String,
    /// Chain admin address
    #[clap(long)]
    pub admin_address: String,
    /// AccessControlRestriction contract address
    #[clap(long)]
    pub access_control_restriction: String,
    /// Skip broadcasting transactions
    #[clap(long, default_value_t = false)]
    pub skip_broadcast: bool,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: ChainUpgradeArgs, shell: &Shell) -> anyhow::Result<()> {
    let _ = shell;
    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let script_path = "deploy-scripts/AdminFunctions.s.sol";

    let mut cmd = Command::new("forge");
    cmd.arg("script")
        .arg(script_path)
        .arg("--sig")
        .arg("upgradeChainFromCTM(address,address,address)")
        .arg(&args.chain_address)
        .arg(&args.admin_address)
        .arg(&args.access_control_restriction)
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

    logger::step("Running chain upgrade via AdminFunctions.s.sol");
    logger::info(format!("Chain address: {}", args.chain_address));
    logger::info(format!("Admin address: {}", args.admin_address));
    logger::info(format!(
        "Access control restriction: {}",
        args.access_control_restriction
    ));
    logger::info(format!("RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("Broadcast: {}", !args.skip_broadcast));

    let output = cmd
        .output()
        .context("Failed to execute forge script for chain upgrade")?;
    if !output.status.success() {
        anyhow::bail!(
            "Forge script failed:\nSTDOUT:\n{}\nSTDERR:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    logger::success("Chain upgrade completed");
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
        "Could not locate l1-contracts under {} (checked l1-contracts and contracts/l1-contracts)",
        repo_root.display()
    )
}
