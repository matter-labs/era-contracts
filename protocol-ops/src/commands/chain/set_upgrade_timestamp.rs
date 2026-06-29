use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};
use crate::common::logger;
use crate::common::SharedRunArgs;

/// Set chain-upgrade timestamp.
///
/// Drives `AdminFunctions.s.sol::adminScheduleUpgrade(admin, acr, version, ts)`
/// against a forked anvil and emits a Gnosis Safe Transaction Builder JSON
/// bundle via `--out`. Apply the bundle separately via
/// `protocol-ops dev execute-safe` (or any Safe-bundle-aware executor).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetUpgradeTimestampArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments (i.e. every local-anvil fixture).
    /// Pass explicitly when the chain uses an access-control-restriction.
    #[clap(long, default_value = "0x0000000000000000000000000000000000000000")]
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
    let (eco, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, eco.bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    // The Solidity script executes via ChainAdmin, but broadcasts from the
    // ChainAdmin owner internally. Use that owner as Forge's sender so Foundry
    // tracks the correct nonce on the anvil fork.
    let sender = runner
        .prepare_chain_admin_owner(eco.bridgehub, chain_id)
        .await?;

    let script_path = Path::new("deploy-scripts/AdminFunctions.s.sol");

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "adminScheduleUpgrade(address,address,uint256,uint256)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Ffi);
    // Broadcast against the anvil fork so Forge records txs into its run
    // file — protocol-ops extracts those into the Safe bundle.
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.additional_args.extend([
        format!("{:#x}", admin_address),
        format!("{:#x}", args.access_control_restriction),
        args.new_protocol_version.clone(),
        args.upgrade_timestamp.clone(),
    ]);

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(script_path, script_args)
        .with_wallet(&sender);

    logger::step(
        "Preparing set-upgrade-timestamp Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Admin address: {:#x}", admin_address));
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
        .context("Failed to prepare set-upgrade-timestamp")?;

    write_output_if_requested(
        "chain.set-upgrade-timestamp",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "admin_address": format!("{:#x}", admin_address),
            "access_control_restriction": format!("{:#x}", args.access_control_restriction),
            "new_protocol_version": &args.new_protocol_version,
            "upgrade_timestamp": &args.upgrade_timestamp,
        }),
    )
    .await?;

    logger::success("Set upgrade timestamp prepared");
    Ok(())
}
