use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::addresses::ZERO_ADDRESS;
use crate::common::chain_upgrade_calls;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct SetUpgradeTimestampOutput {
    admin_address: Address,
    /// The ChainAdmin's owner, who sends the bundle; absent when an AccessControlRestriction
    /// admin sends it instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    chain_admin_owner: Option<Address>,
    access_control_restriction: Address,
    bridgehub: Address,
    chain_id: u64,
    new_protocol_version: String,
    upgrade_timestamp: String,
}

/// Set chain-upgrade timestamp, prepare-only.
///
/// Drives `AdminFunctions.s.sol::adminScheduleUpgrade(admin, acr, version, ts)`
/// against a forked anvil, emits a Gnosis Safe Transaction Builder JSON bundle
/// via `--out`, and never broadcasts. Apply the bundle via
/// `protocol-ops dev execute-safe` (or any Safe-bundle-aware executor).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetUpgradeTimestampArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments (i.e. every local-anvil fixture).
    /// Pass explicitly when the chain uses an access-control-restriction.
    #[clap(long, default_value = ZERO_ADDRESS)]
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
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let new_protocol_version = args
        .new_protocol_version
        .parse::<U256>()
        .context("invalid new_protocol_version: expected decimal or hex uint256")?;
    let upgrade_timestamp = args
        .upgrade_timestamp
        .parse::<U256>()
        .context("invalid upgrade_timestamp: expected decimal or hex uint256")?;

    let call = chain_upgrade_calls::set_upgrade_timestamp(
        &runner,
        bridgehub,
        chain_id,
        args.access_control_restriction,
        new_protocol_version,
        upgrade_timestamp,
    )
    .await?;
    let (admin_address, sender_address) = (call.admin, call.sender.address);

    logger::step(
        "Preparing set-upgrade-timestamp Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Chain ID: {}", chain_id));
    logger::info(format!(
        "New protocol version: {}",
        args.new_protocol_version
    ));
    logger::info(format!("Upgrade timestamp: {}", args.upgrade_timestamp));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    call.run(&mut runner)
        .context("Failed to prepare set-upgrade-timestamp")?;

    crate::common::output::write_output_if_requested(
        "chain.set-upgrade-timestamp",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetUpgradeTimestampOutput {
            admin_address,
            chain_admin_owner: (args.access_control_restriction == Address::ZERO)
                .then_some(sender_address),
            access_control_restriction: args.access_control_restriction,
            bridgehub,
            chain_id,
            new_protocol_version: args.new_protocol_version.clone(),
            upgrade_timestamp: args.upgrade_timestamp.clone(),
        },
    )
    .await?;

    logger::success("Set upgrade timestamp prepared");
    Ok(())
}
