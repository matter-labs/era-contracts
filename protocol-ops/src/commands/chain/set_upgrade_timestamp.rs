use alloy::primitives::{Address, U256};
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::scripts::ADMIN_FUNCTIONS_INVOCATION;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct SetUpgradeTimestampOutput {
    admin_address: Address,
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

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    // The Solidity helper executes through ChainAdmin, but broadcasts from
    // ChainAdmin.owner() or the AccessControlRestriction default admin inside adminExecuteCalls.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, args.access_control_restriction)
        .await?;

    let forge = runner
        .script_with_calldata(
            &ADMIN_FUNCTIONS_INVOCATION,
            AdminFunctionsAbi::adminScheduleUpgradeCall {
                _adminAddr: admin_address,
                _accessControlRestriction: args.access_control_restriction,
                _bridgehub: bridgehub,
                _chainId: U256::from(chain_id),
                _newProtocolVersion: new_protocol_version,
                _timestamp: upgrade_timestamp,
            }
            .abi_encode(),
        )
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
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Chain ID: {}", chain_id));
    logger::info(format!(
        "New protocol version: {}",
        args.new_protocol_version
    ));
    logger::info(format!("Upgrade timestamp: {}", args.upgrade_timestamp));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to prepare set-upgrade-timestamp")?;

    crate::common::output::write_output_if_requested(
        "chain.set-upgrade-timestamp",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetUpgradeTimestampOutput {
            admin_address,
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
