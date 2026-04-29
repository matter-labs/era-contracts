use anyhow::Context;
use clap::Parser;
use ethers::types::{Address, U256};
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;

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
    let (eco, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let new_protocol_version = parse_u256_arg(&args.new_protocol_version)?;
    let upgrade_timestamp = parse_u256_arg(&args.upgrade_timestamp)?;

    // Sender is always the chain admin.
    let sender = runner.prepare_chain_admin(eco.bridgehub, chain_id).await?;
    let admin_address = sender.address;

    let forge = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "adminScheduleUpgrade",
            (
                admin_address,
                args.access_control_restriction,
                new_protocol_version,
                upgrade_timestamp,
            ),
        )?
        // `--broadcast` against the anvil fork. In this mode the
        // target RPC is the anvil fork, so "broadcast" produces no real-chain
        // effect — it just records the tx in forge's run file so protocol-ops can
        // extract it into the Safe bundle.
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

fn parse_u256_arg(value: &str) -> anyhow::Result<U256> {
    if let Some(hex_value) = value.strip_prefix("0x") {
        U256::from_str_radix(hex_value, 16)
            .map_err(|error| anyhow::anyhow!("invalid hex uint256 '{}': {}", value, error))
    } else {
        U256::from_dec_str(value)
            .map_err(|error| anyhow::anyhow!("invalid decimal uint256 '{}': {}", value, error))
    }
}
