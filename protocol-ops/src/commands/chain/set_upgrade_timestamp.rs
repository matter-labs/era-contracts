use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct SetUpgradeTimestampOutput {
    admin_address: Address,
    access_control_restriction: Address,
    new_protocol_version: String,
    upgrade_timestamp: String,
}

/// Set chain-upgrade timestamp.
///
/// Drives `AdminFunctions.s.sol::adminScheduleUpgrade` against a forked anvil
/// and emits a Gnosis Safe Transaction Builder JSON bundle via `--out`. Apply
/// the bundle separately via `protocol-ops dev execute-safe`.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetUpgradeTimestampArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments.
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
    let sender = runner
        .prepare_chain_admin_owner(eco.bridgehub, chain_id)
        .await?;

    let new_protocol_version = args
        .new_protocol_version
        .parse::<U256>()
        .context("invalid new_protocol_version: expected decimal or hex uint256")?;
    let upgrade_timestamp = args
        .upgrade_timestamp
        .parse::<U256>()
        .context("invalid upgrade_timestamp: expected decimal or hex uint256")?;

    logger::step("Preparing set-upgrade-timestamp ops via AdminFunctions.s.sol (simulation)");
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

    crate::common::admin_functions::schedule_upgrade(
        &mut runner,
        &sender,
        admin_address,
        args.access_control_restriction,
        new_protocol_version,
        upgrade_timestamp,
    )
    .context("Failed to run set-upgrade-timestamp")?;

    crate::common::output::write_output_if_requested(
        "chain.set-upgrade-timestamp",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetUpgradeTimestampOutput {
            admin_address,
            access_control_restriction: args.access_control_restriction,
            new_protocol_version: args.new_protocol_version.clone(),
            upgrade_timestamp: args.upgrade_timestamp.clone(),
        },
    )
    .await?;

    logger::success("Set upgrade timestamp prepared");
    Ok(())
}
