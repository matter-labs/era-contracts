//! Migrate a chain *from* a gateway settlement layer back to L1.
//!
//! Mirrors [`super::migrate_to`] in the reverse direction. Exposed as four
//! phase-level subcommands, each emitting one Safe bundle:
//!
//!   phase-0-pause-deposits        pause deposits + notify server (chain admin signs both)
//!   phase-1-submit                send the L1→gateway-L2 start-migration priority tx (chain admin)
//!   phase-2-finalize              finalize on L1 once the gateway has executed+settled (deployer)
//!   phase-3-set-da-validator-pair re-set the chain's L1 DA validator pair (chain admin)
//!
//! Phase 0 reuses `migrate_to::stage_pause_deposits` because deposits have to
//! be paused from the L1 side before the Migrator facet on the gateway will
//! accept the withdrawal priority tx. Phases 1–3 are thin wrappers around a
//! single stage each; the phase names stay to keep the CLI symmetric with
//! `migrate-to` and to match the per-phase workflow split.

use anyhow::Context;
use clap::{Parser, Subcommand};
use ethers::types::{Address, Bytes, H256};
use ethers::utils::hex;
use serde::{Deserialize, Serialize};

use super::migrate_to::{stage_pause_deposits, wait_for_l2_tx_receipt};
use crate::abi::{BridgehubAbi, IChainTypeManagerAbi};
use crate::commands::output::write_output_if_requested;
use crate::common::addresses::L2_L1_MESSENGER;
use crate::common::EcosystemChainArgs;
use crate::common::SharedRunArgs;
use crate::common::{forge::ForgeRunner, logger};
use crate::config::forge_interface::script_params::{
    ADMIN_FUNCTIONS_INVOCATION, GATEWAY_UTILS_INVOCATION,
};
use crate::types::L2DACommitmentScheme;

// ── CLI args ──────────────────────────────────────────────────────────────

/// Migrate a chain from a gateway back to L1 settlement (phase-level flow).
#[derive(Subcommand, Debug)]
#[command(after_long_help = "\
Phases (run in order, with the required waits between them):
  phase-0-pause-deposits         Pause deposits + notify the chain server (chain admin)
  phase-1-submit                 Submit the L1→gateway-L2 start-migration priority tx (chain admin)
  phase-2-finalize               Finalize on L1 after gateway has executed and settled (deployer)
  phase-3-set-da-validator-pair  Re-set the chain's L1 DA validator pair (chain admin)")]
pub enum MigrateFromCommands {
    /// Phase 0: pause-deposits + notify-server. The gateway's Migrator facet
    /// requires deposits paused before the withdrawal priority tx can
    /// execute; notify-server tells the chain server to stop producing new
    /// batches. Chain admin signs both.
    #[command(name = "phase-0-pause-deposits")]
    Phase0PauseDeposits(Phase0PauseDepositsArgs),
    /// Phase 1: send the start-migration L1→gateway-L2 priority tx. The
    /// caller must capture the L2 priority tx hash from the L1 receipt's
    /// `NewPriorityRequest` event and pass it to phase-2 via
    /// `--migration-l2-tx-hash`.
    #[command(name = "phase-1-submit")]
    Phase1Submit(Phase1SubmitArgs),
    /// Phase 2: finalize the migration on L1 once the gateway has executed
    /// and settled the withdrawal. Deployer signs (the call is caller-funded,
    /// not admin-gated).
    #[command(name = "phase-2-finalize")]
    Phase2Finalize(Phase2FinalizeArgs),
    /// Phase 3: re-set the chain's L1 DA validator pair. After migrating
    /// back, the chain settles on L1 and the pair must be restored so
    /// batches commit with the correct DA scheme.
    #[command(name = "phase-3-set-da-validator-pair")]
    Phase3SetDaValidatorPair(Phase3SetDaValidatorPairArgs),
}

// ── Phase args ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase0PauseDepositsArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase1SubmitArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// L1 gas price in wei for the L1→L2 priority tx (default: 1 gwei).
    #[clap(long, default_value = "1000000000")]
    pub l1_gas_price: u64,

    /// L1 diamond cut data hex (`0x…`), forwarded verbatim to
    /// `startMigrateChainFromGateway` so the gateway knows what L1 chain
    /// shape to mint back into when the burn message is consumed.
    ///
    /// If omitted, resolved from L1 by querying the chain's current protocol
    /// version on the CTM and scanning `NewUpgradeCutData` events. Anvil
    /// state dumps drop historical events, so integration tests pass this
    /// explicitly; real chains auto-resolve.
    #[clap(long)]
    pub l1_diamond_cut_data: Option<String>,

    /// Refund recipient address for the L1→L2 priority tx.
    #[clap(long)]
    pub refund_recipient: Address,
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase2FinalizeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// Deployer EOA that finalizes the migration on L1. Not permissioned —
    /// any EOA with L1 gas works; kept explicit because finalize is
    /// caller-funded and the auto-resolved chain admin is typically a
    /// contract (not a signable EOA).
    #[clap(long)]
    pub deployer_address: Address,

    /// Gateway L2 RPC URL (for fetching the withdrawal proof + message).
    #[clap(long)]
    pub gateway_rpc_url: String,

    /// L2 priority tx hash on the gateway, produced by phase-1-submit's L1
    /// transaction. Extract from the `NewPriorityRequest` event in the
    /// phase-1 L1 receipt.
    #[clap(long)]
    pub migration_l2_tx_hash: H256,
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase3SetDaValidatorPairArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// L1 DA validator address to restore after migrating back (e.g. the
    /// rollupL1DAValidator deployed during ecosystem init).
    #[clap(long)]
    pub l1_da_validator: Address,

    /// L2 DA commitment scheme. For ZKsync OS rollup chains:
    /// `blobs-zk-sync-os`.
    #[clap(long, value_enum)]
    pub l2_da_commitment_scheme: L2DACommitmentScheme,
}

// ── Dispatch ──────────────────────────────────────────────────────────────

pub async fn run(cmd: MigrateFromCommands) -> anyhow::Result<()> {
    match cmd {
        MigrateFromCommands::Phase0PauseDeposits(args) => run_phase0_pause_deposits(args).await,
        MigrateFromCommands::Phase1Submit(args) => run_phase1_submit(args).await,
        MigrateFromCommands::Phase2Finalize(args) => run_phase2_finalize(args).await,
        MigrateFromCommands::Phase3SetDaValidatorPair(args) => {
            run_phase3_set_da_validator_pair(args).await
        }
    }
}

// ── Phase 0: pause-deposits + notify-server ───────────────────────────────

pub async fn run_phase0_pause_deposits(args: Phase0PauseDepositsArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    // Pause-deposits is shared with the to-gateway flow: it's the same L1
    // `pauseDepositsBeforeInitiatingMigration` call either direction.
    stage_pause_deposits(&mut runner, bridgehub, chain_id)
        .await
        .context("phase-0 pause-deposits stage")?;
    stage_notify_server_from(&mut runner, bridgehub, chain_id)
        .await
        .context("phase-0 notify-server stage")?;

    write_output_if_requested(
        "chain.gateway.migrate-from.phase-0-pause-deposits",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({ "chain_id": chain_id }),
    )
    .await
}

// ── Phase 1: submit ───────────────────────────────────────────────────────

pub async fn run_phase1_submit(args: Phase1SubmitArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let gateway_chain_id = stage_submit_from(
        &mut runner,
        bridgehub,
        chain_id,
        args.l1_gas_price,
        args.l1_diamond_cut_data.as_deref(),
        args.refund_recipient,
        &args.shared,
    )
    .await
    .context("phase-1 submit stage")?;

    write_output_if_requested(
        "chain.gateway.migrate-from.phase-1-submit",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "gateway_chain_id": gateway_chain_id,
        }),
    )
    .await
}

// ── Phase 3: set-da-validator-pair ────────────────────────────────────────

pub async fn run_phase3_set_da_validator_pair(
    args: Phase3SetDaValidatorPairArgs,
) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    stage_set_da_validator_pair_from(
        &mut runner,
        bridgehub,
        chain_id,
        args.l1_da_validator,
        args.l2_da_commitment_scheme,
    )
    .await
    .context("phase-3 set-da-validator-pair stage")?;

    write_output_if_requested(
        "chain.gateway.migrate-from.phase-3-set-da-validator-pair",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "l1_da_validator": format!("{:#x}", args.l1_da_validator),
        }),
    )
    .await
}

// ── Stage helpers ─────────────────────────────────────────────────────────

pub(crate) async fn stage_notify_server_from(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "notifyServerMigrationFromGateway",
            (bridgehub, chain_id, true),
        )?
        .with_wallet(&sender);

    logger::step("Notifying server about migration from gateway");
    logger::info(format!("Chain ID: {}", chain_id));

    runner
        .run(script)
        .context("Failed to notify server about migration from gateway")?;

    logger::success("Server notified about migration from gateway");
    Ok(())
}

/// Returns the resolved gateway chain id for downstream logging/output.
pub(crate) async fn stage_submit_from(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    l1_gas_price: u64,
    l1_diamond_cut_data: Option<&str>,
    refund_recipient: Address,
    shared: &SharedRunArgs,
) -> anyhow::Result<u64> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    let gateway_chain_id =
        crate::common::l1_contracts::resolve_settlement_layer(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("Failed to resolve gateway chain ID from bridgehub")?;
    logger::info(format!("Gateway chain ID (from L1): {gateway_chain_id}"));

    let l1_diamond_cut_data_hex = match l1_diamond_cut_data {
        Some(provided) => format!("0x{}", provided.trim_start_matches("0x")),
        None => {
            logger::step("Resolving L1 diamond cut data from CTM events");
            let bytes = resolve_l1_diamond_cut_data(&shared.l1_rpc_url, bridgehub, chain_id)
                .await
                .context(
                    "Failed to resolve L1 diamond cut data from chain history; \
                     pass --l1-diamond-cut-data explicitly to skip the lookup",
                )?;
            logger::info(format!(
                "Resolved L1 diamond cut data ({} bytes)",
                bytes.len()
            ));
            format!("0x{}", hex::encode(&bytes))
        }
    };
    let l1_diamond_cut_data = Bytes::from(
        hex::decode(l1_diamond_cut_data_hex.trim_start_matches("0x"))
            .context("invalid L1 diamond cut data hex")?,
    );

    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "startMigrateChainFromGateway",
            (
                bridgehub,
                l1_gas_price,
                chain_id,
                gateway_chain_id,
                l1_diamond_cut_data,
                refund_recipient,
                true,
            ),
        )?
        .with_wallet(&sender);

    logger::step("Submitting chain migration FROM gateway");
    logger::info(format!("Chain ID: {}", chain_id));
    logger::info(format!("Gateway chain ID: {}", gateway_chain_id));
    logger::info(format!("L1 gas price: {}", l1_gas_price));

    runner
        .run(script)
        .context("Failed to start migration from gateway")?;

    logger::success("Migration from gateway submitted");
    logger::info(
        "Next: capture the L2 priority tx hash from the L1 receipt and pass it \
         to phase-2-finalize via `--migration-l2-tx-hash`",
    );
    Ok(gateway_chain_id)
}

pub(crate) async fn stage_set_da_validator_pair_from(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    // Use the existing Admin.setDAValidatorPair flow (NOT the gateway-routed
    // setDAValidatorPairWithGateway) — after migrating back, the chain's
    // settlement layer is L1 and `Admin.setDAValidatorPair` is callable
    // directly via the L1 chain admin.
    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "setDAValidatorPair",
            (
                bridgehub,
                chain_id,
                l1_da_validator,
                l2_da_commitment_scheme as u8,
                true,
            ),
        )?
        .with_wallet(&sender);

    logger::step("Setting L1 DA validator pair (post-migration)");
    runner
        .run(script)
        .context("Failed to set L1 DA validator pair")?;

    logger::success("L1 DA validator pair set");
    Ok(())
}

// ── Phase 2: finalize ─────────────────────────────────────────────────────
//
// Phase 2 has a subtle ordering requirement that the other phases don't:
// the forge runner must be constructed *after* we've observed the gateway's
// migration batch as executed on real L1. With `--simulate`, `ForgeRunner`
// forks L1 at a single block height; any L1 state change after fork creation
// is invisible to the fork. `finishMigrateChainFromGateway` reads the stored
// root for the migration batch and verifies our Merkle proof against it, so
// the fork must include the `executeBatches` tx — otherwise it reverts with
// `InvalidProof()`.

pub async fn run_phase2_finalize(args: Phase2FinalizeArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    // Resolve the gateway chain ID off real L1 BEFORE creating the forge
    // runner. With `--simulate`, `ForgeRunner::new` forks L1 via anvil at a
    // single block height; any L1 state change after the fork is created is
    // invisible to the forked anvil. That's fatal for us because below we
    // need to wait for the gateway to commit+prove+execute the migration
    // batch on real L1 and only then can the fork be created (otherwise
    // `finishMigrateChainFromGateway` reads a stale `chainBatchRoots` entry
    // and reverts with `InvalidProof()`).
    let gateway_chain_id = crate::common::l1_contracts::resolve_settlement_layer(
        &args.shared.l1_rpc_url,
        bridgehub,
        chain_id,
    )
    .await
    .context("Failed to resolve gateway chain ID from bridgehub")?;
    logger::info(format!("Gateway chain ID (from L1): {gateway_chain_id}"));

    // Step 1: wait for the priority tx to execute on the gateway.
    logger::step("Waiting for migration tx to execute on gateway");
    wait_for_l2_tx_receipt(&args.gateway_rpc_url, args.migration_l2_tx_hash)
        .await
        .context("Migration tx did not execute on gateway")?;
    logger::info("Migration tx executed on gateway");

    // Step 2: fetch withdrawal params (proof + L1Messenger payload + indices)
    // by polling until the gateway has settled the batch on L1.
    logger::step("Fetching withdrawal params from gateway");
    let withdrawal = {
        let timeout = std::time::Duration::from_secs(300);
        let start = std::time::Instant::now();
        loop {
            match get_finalize_withdrawal_params(&args.gateway_rpc_url, args.migration_l2_tx_hash)
                .await
            {
                Ok(p) => break p,
                Err(e) => {
                    // Fatal errors (e.g. tx reverted) should not be retried.
                    let msg = format!("{e:#}");
                    if msg.contains("REVERTED") {
                        return Err(e).context("Failed to get withdrawal params");
                    }
                    if start.elapsed() >= timeout {
                        return Err(e).context("Failed to get withdrawal params (timed out)");
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }
        }
    };
    logger::info(format!(
        "Withdrawal: batch={}, l2MessageIndex={}, l2TxNumberInBatch={}, message={} bytes",
        withdrawal.l2_batch_number,
        withdrawal.l2_message_index,
        withdrawal.l2_tx_number_in_batch,
        withdrawal.message.0.len()
    ));

    // Step 2b: wait for the gateway's batch containing the migration tx to be
    // EXECUTED on L1. `finishMigrateChainFromGateway` verifies the proof
    // against L1's stored root for that batch, which only becomes available
    // once the gateway has committed + proved + executed the batch. Skipping
    // this wait reliably causes an `InvalidProof()` revert.
    //
    // We poll the REAL L1 (`args.shared.l1_rpc_url`) rather than
    // `runner.rpc_url`: in `--simulate` mode the latter is a forked anvil
    // that's frozen at the moment the runner started, so it will never
    // observe new `executeBatches` txs the gateway sends to real L1.
    logger::step(format!(
        "Waiting for gateway batch {} to be executed on L1",
        withdrawal.l2_batch_number
    ));
    wait_for_gateway_batch_executed_on_l1(
        &args.shared.l1_rpc_url,
        bridgehub,
        gateway_chain_id,
        withdrawal.l2_batch_number,
    )
    .await
    .context("Waiting for gateway batch L1 execution")?;
    logger::info(format!(
        "Gateway batch {} executed on L1",
        withdrawal.l2_batch_number
    ));

    // Step 3: create the forge runner AFTER the wait above. In `--simulate`
    // mode this forks L1 via anvil at the current block, which now includes
    // the gateway's migration batch in `chainBatchRoots`; creating the
    // runner earlier would pin the fork at a pre-execution L1 state.
    let mut runner = ForgeRunner::new(&args.shared)?;
    // `finishMigrateChainFromGateway` is caller-funded, not admin-gated —
    // use the caller-supplied deployer EOA so the Safe bundle target is a
    // signable address.
    let sender = runner.prepare_sender(args.deployer_address).await?;

    // Step 4: call finishMigrateChainFromGateway via forge (deployer key).
    logger::step("Finalizing migration on L1 (finishMigrateChainFromGateway)");
    let script = runner
        .with_script_call(
            &GATEWAY_UTILS_INVOCATION,
            "finishMigrateChainFromGateway",
            (
                bridgehub,
                chain_id,
                gateway_chain_id,
                withdrawal.l2_batch_number,
                withdrawal.l2_message_index,
                withdrawal.l2_tx_number_in_batch,
                Bytes::from(withdrawal.message.0.to_vec()),
                withdrawal.merkle_proof.clone(),
            ),
        )?
        .with_ffi()
        .with_wallet(&sender);
    runner
        .run(script)
        .context("finishMigrateChainFromGateway failed")?;

    write_output_if_requested(
        "chain.gateway.migrate-from.phase-2-finalize",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "gateway_chain_id": gateway_chain_id,
        }),
    )
    .await?;

    logger::success("Migration from gateway finalized on L1");
    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────

/// L1Messenger event topic for `L1MessageSent(address,bytes32,bytes)`.
fn l1_message_sent_topic() -> H256 {
    H256::from(ethers::utils::keccak256(
        b"L1MessageSent(address,bytes32,bytes)",
    ))
}

/// L1 Messenger system contract address on L2 (`0x...8008`).
fn l1_messenger_address() -> Address {
    L2_L1_MESSENGER.parse().unwrap()
}

#[derive(Debug)]
struct WithdrawalParams {
    l2_batch_number: u64,
    l2_message_index: u64,
    l2_tx_number_in_batch: u16,
    message: Bytes,
    merkle_proof: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcResponse<T> {
    result: Option<T>,
}

#[derive(Debug, Deserialize)]
struct ZksyncL2Receipt {
    #[serde(rename = "logs")]
    logs: Vec<RawLog>,
    #[serde(rename = "l2ToL1Logs")]
    l2_to_l1_logs: Vec<RawL2ToL1Log>,
}

#[derive(Debug, Deserialize)]
struct RawLog {
    address: String,
    topics: Vec<String>,
    data: String,
}

#[derive(Debug, Deserialize)]
struct RawL2ToL1Log {
    sender: String,
    #[serde(rename = "transactionIndex")]
    transaction_index: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct L2ToL1LogProof {
    /// Batch number the log is in — same as the gateway's `l1BatchNumber`
    /// for the containing block, but exposed here directly by the proof RPC.
    /// zksync-os does not decorate `eth_getTransactionReceipt` with
    /// `l1BatchNumber`, so we read it from this response instead.
    batch_number: u64,
    id: u64,
    proof: Vec<String>,
}

/// Build the `FinalizeWithdrawalParams` for the L1Nullifier.finalizeDeposit
/// call: indices of the L2→L1 message in its batch, the message bytes,
/// and a Merkle proof of inclusion.
async fn get_finalize_withdrawal_params(
    gateway_rpc_url: &str,
    tx_hash: H256,
) -> anyhow::Result<WithdrawalParams> {
    let client = reqwest::Client::new();

    // 1. Pull the L2 receipt.
    let receipt_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getTransactionReceipt",
        "params": [format!("{:#x}", tx_hash)],
    });
    // First fetch as raw JSON to log the full response for debugging.
    let raw_resp: serde_json::Value = client
        .post(gateway_rpc_url)
        .json(&receipt_body)
        .send()
        .await?
        .json()
        .await?;
    if let Some(result) = raw_resp.get("result") {
        let status = result.get("status").and_then(|v| v.as_str()).unwrap_or("?");
        let gas_used = result
            .get("gasUsed")
            .and_then(|v| v.as_str())
            .unwrap_or("?");
        let to = result.get("to").and_then(|v| v.as_str()).unwrap_or("?");
        logger::info(format!(
            "Receipt: status={status}, gasUsed={gas_used}, to={to}"
        ));
        if let Some(logs) = result.get("logs") {
            logger::info(format!(
                "Raw receipt logs: {} entries",
                logs.as_array().map(|a| a.len()).unwrap_or(0)
            ));
        }
        // Fail immediately if the L2 priority tx reverted — no point retrying.
        if status == "0x0" {
            // Try to extract revert reason from various fields the server might provide.
            let revert_reason = result
                .get("revertReason")
                .or_else(|| result.get("root").and_then(|r| r.get("revertReason")))
                .and_then(|v| v.as_str())
                .unwrap_or("(not provided in receipt)");

            // Also try to get the tx input data for debugging.
            let tx_body = serde_json::json!({
                "jsonrpc": "2.0", "id": 1,
                "method": "eth_getTransactionByHash",
                "params": [format!("{:#x}", tx_hash)],
            });
            let tx_resp: serde_json::Value = client
                .post(gateway_rpc_url)
                .json(&tx_body)
                .send()
                .await
                .ok()
                .and_then(|r| futures::executor::block_on(r.json()).ok())
                .unwrap_or_default();
            let input_prefix = tx_resp
                .get("result")
                .and_then(|r| r.get("input"))
                .and_then(|v| v.as_str())
                .map(|s| &s[..s.len().min(74)]) // selector + first arg
                .unwrap_or("?");

            // Try eth_call to replay and get revert data.
            let tx_result = result;
            let from_addr = tx_result
                .get("from")
                .and_then(|v| v.as_str())
                .unwrap_or("0x0");
            let input_full = tx_resp
                .get("result")
                .and_then(|r| r.get("input"))
                .and_then(|v| v.as_str())
                .unwrap_or("0x");
            let block_num = tx_result
                .get("blockNumber")
                .and_then(|v| v.as_str())
                .unwrap_or("latest");
            let call_body = serde_json::json!({
                "jsonrpc": "2.0", "id": 1,
                "method": "eth_call",
                "params": [{
                    "from": from_addr,
                    "to": to,
                    "data": input_full,
                }, block_num],
            });
            let call_resp: serde_json::Value = client
                .post(gateway_rpc_url)
                .json(&call_body)
                .send()
                .await
                .ok()
                .and_then(|r| futures::executor::block_on(r.json()).ok())
                .unwrap_or_default();
            let eth_call_error = call_resp
                .get("error")
                .map(|e| format!("{}", e))
                .unwrap_or_else(|| "(no error from eth_call)".to_string());

            anyhow::bail!(
                "L2 priority tx {:#x} REVERTED on gateway (status=0x0, to={to}, gasUsed={gas_used}).\n\
                 Revert reason from receipt: {revert_reason}\n\
                 eth_call replay error: {eth_call_error}\n\
                 Input prefix: {input_prefix}",
                tx_hash,
            );
        }
        if let Some(l2_to_l1) = result.get("l2ToL1Logs") {
            logger::info(format!(
                "Raw receipt l2ToL1Logs: {} entries",
                l2_to_l1.as_array().map(|a| a.len()).unwrap_or(0)
            ));
            if let Some(arr) = l2_to_l1.as_array() {
                for (i, log) in arr.iter().enumerate() {
                    logger::info(format!("  raw l2ToL1Log[{i}]: {}", log));
                }
            }
        }
    }
    let receipt_resp: JsonRpcResponse<ZksyncL2Receipt> =
        serde_json::from_value(raw_resp).context("Failed to parse receipt response")?;
    let receipt = receipt_resp
        .result
        .context("eth_getTransactionReceipt returned null")?;

    // 2. Find the L2→L1 message index in `l2ToL1Logs` for the proof RPC.
    //    `l1Nullifier.finalizeDeposit` (called by `finishMigrateChainFromGateway`)
    //    verifies a leaf where `sender == l2Sender` (hardcoded to
    //    L2_ASSET_ROUTER_ADDR for the migration flow in GatewayUtils.s.sol).
    //    The matching L2→L1 log is the one emitted via the L1Messenger
    //    (`0x8008`) — in the tree, the L1Messenger wraps the actual sender
    //    (the L2AssetRouter) in the leaf. The bootloader (`0x8001`) log is a
    //    separate tx-success marker and is NOT the leaf L1 verifies against.
    //
    //    This matches zksync-era's reference implementation at
    //    `zkstack_cli/crates/common/src/zks_provider.rs::get_withdrawal_l2_to_l1_log`.
    let messenger_lc = format!("{:#x}", l1_messenger_address()).to_lowercase();
    let (l2_to_l1_log_index, l2_tx_number_in_batch) = receipt
        .l2_to_l1_logs
        .iter()
        .enumerate()
        .find(|(_, log)| log.sender.to_lowercase() == messenger_lc)
        .map(|(i, log)| {
            let tx_idx = u16::from_str_radix(log.transaction_index.trim_start_matches("0x"), 16)
                .context("Failed to parse transactionIndex as u16");
            (i as u64, tx_idx)
        })
        .ok_or_else(|| {
            let senders: Vec<_> = receipt
                .l2_to_l1_logs
                .iter()
                .map(|l| l.sender.as_str())
                .collect();
            anyhow::anyhow!(
                "No L2→L1 log from L1Messenger in withdrawal receipt \
                 (found {} logs with senders: {:?})",
                receipt.l2_to_l1_logs.len(),
                senders,
            )
        })?;
    let l2_tx_number_in_batch = l2_tx_number_in_batch?;

    // 3. Find the corresponding `L1MessageSent` event log on L2 to extract
    //    the message body (the proof RPC only returns the merkle path, not
    //    the message itself). L1Messenger is the only legitimate emitter of
    //    this event — same filter as zksync-era's
    //    `get_withdrawal_log` in the zkstack CLI reference implementation.
    let topic = format!("{:#x}", l1_message_sent_topic());
    let log = receipt
        .logs
        .iter()
        .find(|log| {
            log.address.to_lowercase() == messenger_lc
                && log.topics.first().map(|t| t.to_lowercase()) == Some(topic.clone())
        })
        .ok_or_else(|| {
            anyhow::anyhow!(
                "No L1MessageSent event in withdrawal tx logs on gateway \
                 (looked for topic {topic} from {messenger_lc})"
            )
        })?;
    let log_data = hex::decode(log.data.trim_start_matches("0x"))
        .context("Failed to decode L1MessageSent log data hex")?;
    // `event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);`
    // Both `_sender` and `_hash` are indexed — they live in `topics[1..=2]`, not
    // in `data`. The `data` payload carries ONLY the `bytes _message` field.
    let decoded = ethers::abi::decode(&[ethers::abi::ParamType::Bytes], &log_data)
        .context("Failed to ABI-decode L1MessageSent log data")?;
    let message_token = decoded
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("L1MessageSent decoded data missing message field"))?;
    let message: Vec<u8> = message_token
        .into_bytes()
        .ok_or_else(|| anyhow::anyhow!("L1MessageSent message field was not Bytes"))?;

    // 4. Fetch the merkle proof. zksync-os exposes the batch number directly
    //    in the proof response (rather than as an `l1BatchNumber` extension
    //    on `eth_getTransactionReceipt`, which zksync-os does not emit). The
    //    proof RPC itself is the polling signal: it returns `null` until the
    //    containing batch has been sealed.
    let proof_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "zks_getL2ToL1LogProof",
        "params": [format!("{:#x}", tx_hash), l2_to_l1_log_index],
    });
    let proof_resp: JsonRpcResponse<L2ToL1LogProof> = client
        .post(gateway_rpc_url)
        .json(&proof_body)
        .send()
        .await?
        .json()
        .await?;
    let proof = proof_resp
        .result
        .context("zks_getL2ToL1LogProof returned null")?;

    Ok(WithdrawalParams {
        l2_batch_number: proof.batch_number,
        l2_message_index: proof.id,
        l2_tx_number_in_batch,
        message: message.into(),
        merkle_proof: proof.proof,
    })
}

// ── L1 diamond cut data resolution ────────────────────────────────────────

/// Poll L1's gateway diamond proxy until `getTotalBatchesExecuted() >=
/// target_batch`. This is the finality check for the proof we're about to
/// submit — `finishMigrateChainFromGateway` reads the stored root for
/// `target_batch` and verifies our Merkle proof against it, so the batch
/// must have reached the `Executed` state on L1 first.
async fn wait_for_gateway_batch_executed_on_l1(
    l1_rpc_url: &str,
    bridgehub: Address,
    gateway_chain_id: u64,
    target_batch: u64,
) -> anyhow::Result<()> {
    use crate::abi::ZkChainAbi;
    use crate::common::l1_contracts;
    use ethers::providers::{Http, Provider};

    let provider =
        std::sync::Arc::new(Provider::<Http>::try_from(l1_rpc_url).context("connect L1 provider")?);
    let gateway_diamond = l1_contracts::resolve_zk_chain(l1_rpc_url, bridgehub, gateway_chain_id)
        .await
        .context("resolve gateway diamond proxy on L1")?;
    let zk_chain = ZkChainAbi::new(gateway_diamond, provider);

    let timeout = std::time::Duration::from_secs(300);
    let start = std::time::Instant::now();
    let target = ethers::types::U256::from(target_batch);
    loop {
        let executed = zk_chain
            .get_total_batches_executed()
            .call()
            .await
            .context("gateway diamond getTotalBatchesExecuted")?;
        if executed >= target {
            return Ok(());
        }
        if start.elapsed() >= timeout {
            anyhow::bail!(
                "timeout waiting for gateway batch {target_batch} to be executed on L1 \
                 (current executed on L1: {executed})"
            );
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

/// Resolve the L1 diamond cut data for the given chain by:
///   1. Reading `chainTypeManager(chainId)` from the L1 bridgehub
///   2. Reading `getProtocolVersion(chainId)` from the CTM
///   3. Scanning the CTM for `NewUpgradeCutData(uint256 indexed
///      protocolVersion, Diamond.DiamondCutData diamondCutData)` events
///      filtered by that protocol version
///   4. Decoding the matching event's data field and re-encoding it as
///      ABI-encoded `Diamond.DiamondCutData`, the format expected by
///      `startMigrateChainFromGateway`
async fn resolve_l1_diamond_cut_data(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Vec<u8>> {
    use ethers::providers::{Http, Middleware, Provider};
    use ethers::types::{Filter, H256};

    let provider = std::sync::Arc::new(Provider::<Http>::try_from(l1_rpc_url)?);

    // 1) bridgehub.chainTypeManager(chainId)
    let bridgehub = BridgehubAbi::new(bridgehub, provider.clone());
    let ctm = bridgehub
        .chain_type_manager(chain_id.into())
        .call()
        .await
        .context("bridgehub.chainTypeManager call")?;

    // 2) ctm.getProtocolVersion(chainId)
    let ctm_contract = IChainTypeManagerAbi::new(ctm, provider.clone());
    let protocol_version = ctm_contract
        .get_protocol_version(chain_id.into())
        .call()
        .await
        .context("ctm.getProtocolVersion call")?;

    // 3) scan CTM for NewUpgradeCutData(protocolVersion, ...)
    let topic0 = H256::from(ethers::utils::keccak256(
        b"NewUpgradeCutData(uint256,(((address,uint8,bool,bytes4[]))[],address,bytes))",
    ));
    let mut version_topic = [0u8; 32];
    protocol_version.to_big_endian(&mut version_topic);
    let topic1 = H256::from(version_topic);
    let filter = Filter::new()
        .address(ctm)
        .topic0(topic0)
        .topic1(topic1)
        .from_block(0u64);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for NewUpgradeCutData")?;
    let log = logs.last().ok_or_else(|| {
        anyhow::anyhow!(
            "No NewUpgradeCutData event for protocol version {protocol_version} on CTM {ctm:#x}"
        )
    })?;

    // 4) The event's only non-indexed parameter is `Diamond.DiamondCutData
    //    diamondCutData`, which is a struct: `(FacetCut[], address, bytes)`.
    //    The event log data is the ABI-encoding of a single tuple containing
    //    that struct. After decoding we re-encode the inner struct alone,
    //    which is the format `startMigrateChainFromGateway` expects.
    use ethers::abi::ParamType;
    let facet_cut = ParamType::Tuple(vec![
        ParamType::Address,                                   // facet
        ParamType::Uint(8),                                   // action
        ParamType::Bool,                                      // isFreezable
        ParamType::Array(Box::new(ParamType::FixedBytes(4))), // selectors
    ]);
    let diamond_cut_data = ParamType::Tuple(vec![
        ParamType::Array(Box::new(facet_cut)), // facetCuts
        ParamType::Address,                    // initAddress
        ParamType::Bytes,                      // initCalldata
    ]);
    let tokens = ethers::abi::decode(&[diamond_cut_data], &log.data)
        .context("ABI-decode NewUpgradeCutData log")?;
    let inner = tokens
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("NewUpgradeCutData decoded into zero tokens"))?;
    Ok(ethers::abi::encode(&[inner]))
}
