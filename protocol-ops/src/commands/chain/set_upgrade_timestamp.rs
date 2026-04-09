use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetUpgradeTimestampArgs {
    /// Chain admin address
    #[clap(long)]
    pub admin_address: Address,
    /// AccessControlRestriction contract address
    #[clap(long)]
    pub access_control_restriction: Address,
    /// New packed protocol version (uint256)
    #[clap(long)]
    pub new_protocol_version: String,
    /// Upgrade timestamp (unix seconds)
    #[clap(long)]
    pub upgrade_timestamp: String,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainSetUpgradeTimestampArgs) -> anyhow::Result<()> {
    let private_key = args
        .shared
        .private_key
        .ok_or_else(|| anyhow::anyhow!("--private-key is required"))?;

    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    let script_path = Path::new("deploy-scripts/AdminFunctions.s.sol");

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "adminScheduleUpgrade(address,address,uint256,uint256)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::PrivateKey {
        private_key: format!("{:#x}", private_key),
    });
    script_args.additional_args.extend([
        format!("{:#x}", args.admin_address),
        format!("{:#x}", args.access_control_restriction),
        args.new_protocol_version.clone(),
        args.upgrade_timestamp.clone(),
    ]);

    let forge = Forge::new(&runner.foundry_scripts_path).script(script_path, script_args);

    logger::step("Setting chain upgrade timestamp via AdminFunctions.s.sol");
    logger::info(format!("Admin address: {:#x}", args.admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!(
        "New protocol version: {}",
        args.new_protocol_version
    ));
    logger::info(format!("Upgrade timestamp: {}", args.upgrade_timestamp));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to set upgrade timestamp")?;

    write_output_if_requested(
        "chain.set-upgrade-timestamp",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "admin_address": format!("{:#x}", args.admin_address),
            "access_control_restriction": format!("{:#x}", args.access_control_restriction),
            "new_protocol_version": &args.new_protocol_version,
            "upgrade_timestamp": &args.upgrade_timestamp,
        }),
    )
    .await?;

    logger::success("Set upgrade timestamp completed");
    Ok(())
}
