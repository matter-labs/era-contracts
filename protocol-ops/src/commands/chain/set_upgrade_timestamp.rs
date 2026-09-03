use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct SetUpgradeTimestampOutput {
    admin_address: Address,
    access_control_restriction: Address,
    bridgehub: Address,
    chain_id: u64,
    upgrade_timestamp: String,
}

/// Set chain-upgrade timestamp, prepare-only.
///
/// Drives `AdminFunctions.s.sol::adminScheduleUpgrade(admin, acr, bridgehub, chainId, ts)`
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
    /// Upgrade timestamp (unix seconds)
    #[clap(long)]
    pub upgrade_timestamp: String,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

/// Human-readable rendering of the error selectors
/// `ServerNotifier.previewUpgradePreconditions` reports.
fn describe_precondition_failure(selector: &[u8; 4]) -> String {
    use crate::common::abi::IUpgradePreconditionErrors as E;
    use alloy::sol_types::SolError;

    match *selector {
        s if s == E::CutDataForProtocolVersionNotAvailable::SELECTOR => {
            "CutDataForProtocolVersionNotAvailable: the CTM has no upgrade cut registered for the \
             chain's current protocol version (run the ecosystem upgrade prepare first)"
                .to_string()
        }
        s if s == E::BaseTokenPreV31TotalSupplyNotSet::SELECTOR => {
            "BaseTokenPreV31TotalSupplyNotSet: the chain's pre-v31 base-token total supply was \
             never backfilled"
                .to_string()
        }
        s if s == E::LowerBoundNotRecorded::SELECTOR => {
            "LowerBoundNotRecorded: the chain's priority-op lower bound is not recorded yet (run \
             RecordPriorityOpLowerBound.s.sol)"
                .to_string()
        }
        s if s == E::PriorityQueueNotReady::SELECTOR => {
            "PriorityQueueNotReady: priority ops below the recorded lower bound are not fully \
             processed yet"
                .to_string()
        }
        s if s == E::ZKChainNotRegistered::SELECTOR => {
            "ZKChainNotRegistered: the CTM has no chain registered under this chain id".to_string()
        }
        s => format!("unknown precondition error selector 0x{}", hex::encode(s)),
    }
}

pub async fn run(args: ChainSetUpgradeTimestampArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let upgrade_timestamp = args
        .upgrade_timestamp
        .parse::<U256>()
        .context("invalid upgrade_timestamp: expected decimal or hex uint256")?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;

    // Dry-run the on-chain scheduling preconditions and fail fast with a readable message. The
    // forge simulation below would surface the same failure, but only as a bare revert selector;
    // the on-chain check in `ServerNotifier.setUpgradeTimestamp` stays the source of truth.
    let server_notifier = crate::common::l1_contracts::resolve_server_notifier(
        &args.shared.l1_rpc_url,
        bridgehub,
        chain_id,
    )
    .await
    .context("resolving ServerNotifier from L1")?;
    match crate::common::l1_contracts::preview_upgrade_preconditions(
        &args.shared.l1_rpc_url,
        server_notifier,
        chain_id,
    )
    .await?
    {
        Some(failed) if !failed.is_empty() => {
            let lines: Vec<String> = failed
                .iter()
                .map(|s| format!("  - {}", describe_precondition_failure(s)))
                .collect();
            anyhow::bail!(
                "chain {chain_id} is not ready to have its upgrade scheduled \
                 (ServerNotifier.previewUpgradePreconditions):\n{}",
                lines.join("\n")
            );
        }
        Some(_) => logger::info("On-chain upgrade-scheduling preconditions: OK"),
        None => logger::info(
            "ServerNotifier predates the precondition preview; relying on the scheduling call's own checks",
        ),
    }
    // The Solidity helper executes through ChainAdmin, but broadcasts from
    // ChainAdmin.owner() or the AccessControlRestriction default admin inside adminExecuteCalls.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, args.access_control_restriction)
        .await?;

    let forge = runner
        .script_call(AdminFunctionsAbi::adminScheduleUpgradeCall {
            _adminAddr: admin_address,
            _accessControlRestriction: args.access_control_restriction,
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
            _timestamp: upgrade_timestamp,
        })
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
            upgrade_timestamp: args.upgrade_timestamp.clone(),
        },
    )
    .await?;

    logger::success("Set upgrade timestamp prepared");
    Ok(())
}
