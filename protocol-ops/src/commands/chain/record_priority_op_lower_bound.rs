use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::IRecordPriorityOpLowerBoundAbi;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct RecordPriorityOpLowerBoundOutput {
    chain_id: u64,
    bridgehub: Address,
    priority_op_lower_bound: Address,
    sender: Address,
}

/// Record a ZKsync OS chain's priority-op lower bound ahead of its upgrade.
///
/// Drives `deploy-scripts/upgrade/v33/RecordPriorityOpLowerBound.s.sol` against a forked anvil and
/// emits a Safe bundle via `--out`, like the other prepare-only commands. Apply it with
/// `protocol-ops dev execute-safe`. Keep it as its own bundle rather than folding it into the
/// governance one: the call is permissionless and has to land in a separate, earlier transaction.
///
/// This is a mandatory prerequisite of the v33 per-chain upgrade: `V32UpgradeZKsyncOS` rejects the
/// diamond cut until the bound is recorded *and* every priority op below it has been processed on
/// L2, which together prove the v31 base-token supply backfill executed before this release removed
/// its L2 entry point. Run it, wait for `getFirstUnprocessedPriorityTx()` to reach the recorded
/// bound, and only then run `chain upgrade`.
///
/// The registry address is the CTM prepare output's `state_transition.priority_op_lower_bound_addr`
/// (`script-out/v33-upgrade-ctm-<ctm>.toml`, written by `ecosystem upgrade-prepare-all`).
///
/// Idempotent: the script no-ops when a bound is already recorded for the chain.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainRecordPriorityOpLowerBoundArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// `PriorityOpLowerBound` registry deployed by the CTM prepare step.
    #[clap(long)]
    pub priority_op_lower_bound: Address,

    /// EOA that will send the recording transaction. Any funded address will do — the registry call
    /// is permissionless and grants the sender nothing — but it must match the key used to apply the
    /// emitted bundle, since that address is what lands in the bundle's `from`.
    #[clap(long)]
    pub sender: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainRecordPriorityOpLowerBoundArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let forge = runner
        .script_call(IRecordPriorityOpLowerBoundAbi::runCall {
            _priorityOpLowerBound: args.priority_op_lower_bound,
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
        })
        .with_broadcast()
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_sender(format!("{:#x}", args.sender))
        .with_unlocked();

    logger::step("Preparing the priority-op lower-bound recording bundle");
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Chain ID: {chain_id}"));
    logger::info(format!(
        "PriorityOpLowerBound: {:#x}",
        args.priority_op_lower_bound
    ));

    runner
        .run(forge)
        .context("Failed to execute forge script for record-priority-op-lower-bound")?;

    crate::common::output::write_output_if_requested(
        "chain.record-priority-op-lower-bound",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &RecordPriorityOpLowerBoundOutput {
            chain_id,
            bridgehub,
            priority_op_lower_bound: args.priority_op_lower_bound,
            sender: args.sender,
        },
    )
    .await?;

    logger::success("priority-op lower-bound recording prepared");
    Ok(())
}
