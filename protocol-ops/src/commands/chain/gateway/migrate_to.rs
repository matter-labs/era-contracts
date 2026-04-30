use anyhow::Context;
use clap::{Parser, Subcommand};
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::abi::{BridgehubAbi, IChainTypeManagerAbi};
use crate::commands::output::write_output_if_requested;
use crate::common::addresses::{GATEWAY_L2_BRIDGEHUB, L2_BOOTLOADER};
use crate::common::EcosystemChainArgs;
use crate::common::SharedRunArgs;
use crate::common::{forge::ForgeRunner, logger};
use crate::config::forge_interface::script_params::{
    ADMIN_FUNCTIONS_INVOCATION, GATEWAY_UTILS_INVOCATION,
};

use crate::types::L2DACommitmentScheme;

// ── Step 1: Pause deposits ------------------------------------------------

/// Run the `pause-deposits` stage against an existing `runner` fork.
/// Reusable from phase-0-pause-deposits.
pub(crate) async fn stage_pause_deposits(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    // Always broadcast the admin call, including in `--simulate`. The simulate
    // fork is ephemeral, but the Safe bundle is built from forge's broadcast
    // log, so the admin tx must be in there for downstream replay.
    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "pauseDepositsBeforeInitiatingMigration",
            (bridgehub, chain_id, true),
        )?
        .with_wallet(&sender);

    logger::step("Pausing deposits before migration");
    logger::info(format!("Chain ID: {}", chain_id));

    runner.run(script).context("Failed to pause deposits")?;
    logger::success("Deposits paused");
    Ok(())
}

// ── Step 2: Notify server --------------------------------------------------

/// Run the `notify-server` stage against an existing `runner` fork.
/// Reusable from phase-level composite commands (migrate-to phase-1-submit,
/// phase-0-pause-deposits, …) that chain multiple stages on one fork.
pub(crate) async fn stage_notify_server(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    // See pause-deposits for the rationale — always broadcast in simulate too
    // so the tx shows up in the bundle's --out / Safe file.
    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "notifyServerMigrationToGateway",
            (bridgehub, chain_id, true),
        )?
        .with_wallet(&sender);

    logger::step("Notifying server about migration");
    logger::info(format!("Chain ID: {}", chain_id));

    runner
        .run(script)
        .context("Failed to notify server about migration")?;

    logger::success("Server notified about migration");
    Ok(())
}

// ── Step 3: Submit ---------------------------------------------------------

/// Run the `submit` stage (migrateChainToGateway) against an existing
/// `runner` fork. Reusable from phase-1-submit.
pub(crate) async fn stage_submit(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    gateway_chain_id: u64,
    gateway_rpc_url: String,
    l1_gas_price: u64,
    refund_recipient: Address,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    // See pause-deposits for the rationale — always broadcast in simulate too
    // so the tx shows up in the bundle's --out / Safe file. The script
    // fork-switches to `gateway_rpc_url` to read the gateway-side CTM's
    // diamond cut data before constructing the migration message.
    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "migrateChainToGateway",
            (
                bridgehub,
                l1_gas_price,
                chain_id,
                gateway_chain_id,
                gateway_rpc_url,
                refund_recipient,
                true,
            ),
        )?
        .with_wallet(&sender);

    logger::step("Submitting chain migration to gateway");
    logger::info(format!("Chain ID: {}", chain_id));
    logger::info(format!("Gateway chain ID: {}", gateway_chain_id));
    logger::info(format!("L1 gas price: {}", l1_gas_price));

    runner
        .run(script)
        .context("Failed to migrate chain to gateway")?;

    logger::success("Chain migration submitted");
    Ok(())
}

// Finalize doesn't have a `stage_*` helper: its ordering constraints (fork
// L1 only after the gateway's migration batch has settled on real L1) are
// unique to that phase, so the full body lives in `run_phase2_finalize` below.

// ── enable-validators ─────────────────────────────────────────────────────

/// Inputs for the enable-validators stage. Grouped so phase-3 can thread
/// the same set through two separate stages.
pub(crate) struct EnableValidatorsInputs<'a> {
    pub commit_operator: Address,
    pub prove_operator: Address,
    pub execute_operator: Address,
    pub gateway_validator_timelock: Option<Address>,
    pub gateway_rpc_url: &'a str,
    pub l1_gas_price: u64,
}

/// Run the `enable-validators` stage against an existing `runner` fork.
/// Returns `(gateway_chain_id, n_validators)` for downstream logging /
/// output.
pub(crate) async fn stage_enable_validators(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    inputs: &EnableValidatorsInputs<'_>,
) -> anyhow::Result<(u64, usize)> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    let gateway_chain_id =
        crate::common::l1_contracts::resolve_settlement_layer(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("Failed to resolve gateway chain ID from bridgehub")?;
    logger::info(format!("Gateway chain ID (from L1): {gateway_chain_id}"));

    // Resolve ValidatorTimelock
    logger::step("Resolving gateway ValidatorTimelock");
    let gw_validator_timelock = match inputs.gateway_validator_timelock {
        Some(addr) => addr,
        None => resolve_gateway_validator_timelock(inputs.gateway_rpc_url, chain_id)
            .await
            .context(
                "Failed to resolve gateway ValidatorTimelock \
                 (pass --gateway-validator-timelock to skip RPC resolution)",
            )?,
    };
    logger::info(format!(
        "Gateway ValidatorTimelock: {:#x}",
        gw_validator_timelock
    ));

    // Deduplicate operators
    let validators: Vec<Address> = {
        let mut v = vec![
            inputs.commit_operator,
            inputs.prove_operator,
            inputs.execute_operator,
        ];
        v.sort();
        v.dedup();
        v.retain(|a| *a != Address::zero());
        v
    };

    logger::step("Enabling validators on gateway");
    for validator in &validators {
        logger::info(format!("Enabling validator {:#x}", validator));
        let script = runner
            .with_script_call(
                &ADMIN_FUNCTIONS_INVOCATION,
                "enableValidatorViaGateway",
                (
                    bridgehub,
                    inputs.l1_gas_price,
                    chain_id,
                    gateway_chain_id,
                    *validator,
                    gw_validator_timelock,
                    sender.address,
                    true,
                ),
            )?
            .with_wallet(&sender);
        runner
            .run(script)
            .with_context(|| format!("enableValidatorViaGateway for {:#x}", validator))?;
    }

    logger::success("Validators enabled on gateway");
    Ok((gateway_chain_id, validators.len()))
}

// ── set-da-validator-pair ─────────────────────────────────────────────────

/// Inputs for the set-da-validator-pair stage.
pub(crate) struct SetDaValidatorPairInputs<'a> {
    pub l1_da_validator: Address,
    pub l2_da_commitment_scheme: L2DACommitmentScheme,
    pub gateway_rpc_url: &'a str,
    pub l1_gas_price: u64,
}

/// Run the `set-da-validator-pair` stage. Returns
/// `(gateway_chain_id, chain_diamond_on_gateway)`.
pub(crate) async fn stage_set_da_validator_pair(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    inputs: &SetDaValidatorPairInputs<'_>,
) -> anyhow::Result<(u64, Address)> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    let gateway_chain_id =
        crate::common::l1_contracts::resolve_settlement_layer(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("Failed to resolve gateway chain ID from bridgehub")?;
    logger::info(format!("Gateway chain ID (from L1): {gateway_chain_id}"));

    // Resolve the chain's diamond proxy on the gateway via L2 RPC.
    logger::step("Resolving chain diamond proxy on gateway");
    let chain_diamond_on_gw = resolve_chain_diamond_on_gateway(inputs.gateway_rpc_url, chain_id)
        .await
        .context("Failed to resolve chain diamond proxy on gateway")?;
    logger::info(format!(
        "Chain {} diamond proxy on gateway: {:#x}",
        chain_id, chain_diamond_on_gw
    ));

    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "setDAValidatorPairWithGateway",
            (
                bridgehub,
                inputs.l1_gas_price,
                chain_id,
                gateway_chain_id,
                inputs.l1_da_validator,
                inputs.l2_da_commitment_scheme as u8,
                chain_diamond_on_gw,
                sender.address,
                true,
            ),
        )?
        .with_wallet(&sender);

    runner
        .run(script)
        .context("setDAValidatorPairWithGateway failed")?;

    logger::success("DA validator pair set via gateway");
    Ok((gateway_chain_id, chain_diamond_on_gw))
}

/// Resolve a chain's diamond proxy address on the gateway by querying the
/// gateway's L2 bridgehub.
async fn resolve_chain_diamond_on_gateway(
    gateway_rpc_url: &str,
    chain_id: u64,
) -> anyhow::Result<Address> {
    use ethers::providers::{Http, Provider};

    let provider = std::sync::Arc::new(Provider::<Http>::try_from(gateway_rpc_url)?);
    let gw_bridgehub: Address = GATEWAY_L2_BRIDGEHUB.parse()?;
    let bridgehub = BridgehubAbi::new(gw_bridgehub, provider);
    let addr = bridgehub
        .get_zk_chain(chain_id.into())
        .call()
        .await
        .context("gateway L2 getZKChain call")?;
    anyhow::ensure!(
        addr != Address::zero(),
        "getZKChain({chain_id}) returned zero — chain not registered on gateway"
    );

    Ok(addr)
}

// ── Helpers ----------------------------------------------------------------

/// Resolve the gateway's ValidatorTimelock address by querying the gateway L2 RPC.
///
/// Looks up the CTM via `bridgehub.chainTypeManager(chain_id)` on the gateway
/// L2 — the `chain_id` must be a chain that has completed migration finalize
/// (registered on the gateway L2 bridgehub via `forwardedBridgeMint`).
async fn resolve_gateway_validator_timelock(
    gateway_rpc_url: &str,
    chain_id: u64,
) -> anyhow::Result<Address> {
    use ethers::providers::{Http, Provider};

    let provider = std::sync::Arc::new(Provider::<Http>::try_from(gateway_rpc_url)?);
    let gw_bridgehub: Address = GATEWAY_L2_BRIDGEHUB.parse()?;
    let bridgehub = BridgehubAbi::new(gw_bridgehub, provider.clone());

    let ctm = bridgehub
        .chain_type_manager(chain_id.into())
        .call()
        .await
        .context("gateway L2 chainTypeManager call")?;
    anyhow::ensure!(
        ctm != Address::zero(),
        "gateway L2 bridgehub.chainTypeManager({chain_id}) returned zero — \
         chain not registered on the gateway. \
         Ensure migration finalize (phase 2) has completed before enable-validators (phase 3)."
    );
    logger::info(format!("Gateway L2 CTM (from chain {chain_id}): {ctm:#x}"));

    let ctm = IChainTypeManagerAbi::new(ctm, provider);
    let timelock = ctm
        .validator_timelock_post_v29()
        .call()
        .await
        .context("gateway L2 validatorTimelockPostV29 call")?;

    Ok(timelock)
}

/// Find the migration transaction by scanning L1 for `MigrationStarted` events.
///
/// The event is emitted by the L1ChainAssetHandler (not the Bridgehub itself),
/// so we first resolve the chainAssetHandler address from the bridgehub.
async fn find_migration_tx(
    l1_rpc_url: &str,
    bridgehub_address: Address,
    chain_id: u64,
    lookback_blocks: u64,
) -> anyhow::Result<ethers::types::H256> {
    use ethers::providers::{Http, Middleware, Provider};
    use ethers::types::Filter;

    let provider = Provider::<Http>::try_from(l1_rpc_url)?;

    // Resolve the chainAssetHandler from the bridgehub — that's where
    // MigrationStarted is emitted.
    let bridgehub =
        crate::abi::BridgehubAbi::new(bridgehub_address, std::sync::Arc::new(provider.clone()));
    let chain_asset_handler: Address = bridgehub
        .chain_asset_handler()
        .call()
        .await
        .context("Failed to read chainAssetHandler from bridgehub")?;

    let latest_block = provider.get_block_number().await?.as_u64();
    let from_block = latest_block.saturating_sub(lookback_blocks);

    let topic0 = ethers::types::H256::from(ethers::utils::keccak256(
        b"MigrationStarted(uint256,uint256,bytes32,uint256)",
    ));
    let chain_id_topic = ethers::types::H256::from({
        let mut buf = [0u8; 32];
        buf[24..32].copy_from_slice(&chain_id.to_be_bytes());
        buf
    });

    let filter = Filter::new()
        .address(chain_asset_handler)
        .topic0(topic0)
        .topic1(chain_id_topic)
        .from_block(from_block)
        .to_block(latest_block);

    let logs = provider
        .get_logs(&filter)
        .await
        .context("Failed to query MigrationStarted events")?;

    if let Some(log) = logs.last() {
        return log
            .transaction_hash
            .context("MigrationStarted event has no tx hash");
    }

    anyhow::bail!(
        "No MigrationStarted event found for chain {} from chainAssetHandler {:#x} (bridgehub {:#x}) in blocks {}..{} (use --lookback-blocks to widen the search)",
        chain_id,
        chain_asset_handler,
        bridgehub_address,
        from_block,
        latest_block,
    )
}

/// Extract the first priority op hash from the migration L1 receipt.
pub(super) async fn extract_priority_op_hash(
    l1_rpc_url: &str,
    tx_hash: ethers::types::H256,
    gateway_diamond_proxy: Address,
) -> anyhow::Result<ethers::types::H256> {
    use ethers::providers::{Http, Middleware, Provider};

    let provider = Provider::<Http>::try_from(l1_rpc_url)?;
    let receipt = provider
        .get_transaction_receipt(tx_hash)
        .await?
        .context("Migration tx receipt not found")?;

    let topic0 = ethers::utils::keccak256(
        b"NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])",
    );
    let topic0 = ethers::types::H256::from(topic0);

    for log in &receipt.logs {
        if log.topics.first() == Some(&topic0)
            && log.address == gateway_diamond_proxy
            && log.data.len() >= 64
        {
            return Ok(ethers::types::H256::from_slice(&log.data[32..64]));
        }
    }

    anyhow::bail!(
        "No NewPriorityRequest log found from gateway diamond proxy {:#x} in tx {:#x}",
        gateway_diamond_proxy,
        tx_hash,
    )
}

// ── RPC response types for typed deserialization ──────────────────────────

#[derive(Debug, Deserialize)]
struct JsonRpcResponse<T> {
    result: Option<T>,
}

#[derive(Debug, Deserialize)]
struct L2ToL1Log {
    sender: String,
    #[serde(rename = "transactionIndex")]
    transaction_index: String,
}

#[derive(Debug, Deserialize)]
struct GatewayTransactionReceipt {
    #[serde(rename = "l2ToL1Logs")]
    l2_to_l1_logs: Vec<L2ToL1Log>,
}

#[derive(Debug, Deserialize)]
struct L2ToL1LogProof {
    #[serde(rename = "batchNumber")]
    batch_number: u64,
    id: u64,
    proof: Vec<String>,
}

// ── RPC helpers ───────────────────────────────────────────────────────────

/// Wait for an L2 transaction receipt on the gateway.
pub(super) async fn wait_for_l2_tx_receipt(
    gateway_rpc_url: &str,
    tx_hash: ethers::types::H256,
) -> anyhow::Result<()> {
    let client = reqwest::Client::new();
    let timeout = std::time::Duration::from_secs(300);
    let start = std::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            anyhow::bail!("Timed out waiting for L2 tx {:#x} on gateway", tx_hash);
        }

        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getTransactionReceipt",
            "params": [format!("{:#x}", tx_hash)]
        });
        let resp: JsonRpcResponse<serde_json::Value> = client
            .post(gateway_rpc_url)
            .json(&body)
            .send()
            .await?
            .json()
            .await?;
        if resp.result.is_some() {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

#[derive(Debug)]
struct FinalizeParams {
    batch_number: u64,
    l2_message_index: u64,
    l2_tx_number_in_batch: u16,
    merkle_proof: Vec<String>,
}

/// Get finalization params (batch number, message index, proof) from the gateway.
async fn get_finalize_params(
    gateway_rpc_url: &str,
    tx_hash: ethers::types::H256,
) -> anyhow::Result<FinalizeParams> {
    let client = reqwest::Client::new();

    // Fetch the transaction receipt to find the bootloader L2->L1 log.
    let receipt_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getTransactionReceipt",
        "params": [format!("{:#x}", tx_hash)]
    });
    let receipt_raw: serde_json::Value = client
        .post(gateway_rpc_url)
        .json(&receipt_body)
        .send()
        .await?
        .json()
        .await?;
    eprintln!(
        "[debug get_finalize_params] raw receipt for {tx_hash:#x}: {}",
        serde_json::to_string_pretty(&receipt_raw).unwrap_or_default()
    );
    let receipt_resp: JsonRpcResponse<GatewayTransactionReceipt> =
        serde_json::from_value(receipt_raw)?;
    let receipt = receipt_resp
        .result
        .context("eth_getTransactionReceipt returned null")?;

    let bootloader = L2_BOOTLOADER;
    let mut log_index = None;
    let mut tx_number_in_batch = 0u16;
    for (i, log) in receipt.l2_to_l1_logs.iter().enumerate() {
        if log.sender.to_lowercase() == bootloader {
            log_index = Some(i);
            let tx_index_str = &log.transaction_index;
            tx_number_in_batch = u16::from_str_radix(tx_index_str.trim_start_matches("0x"), 16)
                .context(format!(
                    "Failed to parse transactionIndex '{}' as u16",
                    tx_index_str
                ))?;
            break;
        }
    }
    let log_index =
        log_index.context("No L2->L1 log from bootloader (0x8001) in migration tx receipt")?;

    // Fetch the L2->L1 log proof.
    let proof_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "zks_getL2ToL1LogProof",
        "params": [format!("{:#x}", tx_hash), log_index]
    });
    let proof_raw: serde_json::Value = client
        .post(gateway_rpc_url)
        .json(&proof_body)
        .send()
        .await?
        .json()
        .await?;
    eprintln!(
        "[debug get_finalize_params] zks_getL2ToL1LogProof(tx={tx_hash:#x}, log_index={log_index}) → {}",
        serde_json::to_string_pretty(&proof_raw).unwrap_or_default()
    );
    eprintln!(
        "[debug get_finalize_params] tx_number_in_batch={tx_number_in_batch}, log_index={log_index}",
    );
    let proof_resp: JsonRpcResponse<L2ToL1LogProof> = serde_json::from_value(proof_raw)?;
    let proof = proof_resp
        .result
        .context("zks_getL2ToL1LogProof returned null")?;

    Ok(FinalizeParams {
        batch_number: proof.batch_number,
        l2_message_index: proof.id,
        l2_tx_number_in_batch: tx_number_in_batch,
        merkle_proof: proof.proof,
    })
}

// ════════════════════════════════════════════════════════════════════════
// Phase-level commands
//
// Each phase runs one or more of the `stage_*` helpers above against a
// single anvil fork, emitting one merged Safe bundle. The CLI surface
// exposes only these phase commands — fine-grained single-stage entry
// points were removed because they duplicated setup boilerplate (resolve
// bridgehub + chain, build runner, prepare sender, write output) for every
// stage and were never used independently.
// ════════════════════════════════════════════════════════════════════════

/// High-level migrate-to-gateway phases. Each phase emits one Safe bundle
/// that replays all its internal stages in order under the correct signers.
#[derive(Subcommand, Debug)]
pub enum MigrateToCommands {
    /// Phase 0: pause-deposits + notify-server — chain admin signs both.
    /// Used on live L1-settling chains before initiating migration so no
    /// new deposits arrive while the chain drains its commit/execute
    /// pipeline.
    #[command(name = "phase-0-pause-deposits")]
    Phase0PauseDeposits(Phase0PauseDepositsArgs),
    /// Phase 1: notify-server + submit — chain admin signs both; produces a
    /// Safe bundle of two chained ChainAdmin.multicall calls.
    #[command(name = "phase-1-submit")]
    Phase1Submit(Phase1SubmitArgs),
    /// Phase 2: finalize the migration on L1 once the gateway has
    /// executed + settled the migration priority tx. Deployer signs (the
    /// call is caller-funded, not admin-gated).
    #[command(name = "phase-2-finalize")]
    Phase2Finalize(Phase2FinalizeArgs),
    /// Phase 3: enable-validators + set-da-validator-pair — chain admin
    /// signs both; runs after the chain has settled on the gateway and
    /// wires validators / DA pair via the gateway.
    #[command(name = "phase-3-validators")]
    Phase3Validators(Phase3ValidatorsArgs),
}

// ── Phase 1: notify-server + submit ──────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase1SubmitArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// Gateway chain ID (the settlement layer to migrate to).
    #[clap(long)]
    pub gateway_chain_id: u64,

    /// Gateway L2 RPC URL. The script fork-switches into the gateway L2
    /// to read its CTM's diamond cut data (whose hash gateway L2 will
    /// check at chain registration). Required because the gateway-side
    /// CTM only exists on gateway L2 — its predicted CREATE2 address has
    /// no code on L1.
    #[clap(long)]
    pub gateway_rpc_url: String,

    /// L1 gas price in wei for the L1->gateway-L2 priority tx.
    #[clap(long)]
    pub l1_gas_price: u64,

    /// Refund recipient address for the L1->L2 priority tx.
    #[clap(long)]
    pub refund_recipient: Address,
}

pub async fn run_phase1_submit(args: Phase1SubmitArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    // Both stages share one anvil fork — forge's broadcast log appends in
    // call order, so Safe-bundle ordering is natural.
    stage_notify_server(&mut runner, bridgehub, chain_id)
        .await
        .context("phase-1 notify-server stage")?;
    stage_submit(
        &mut runner,
        bridgehub,
        chain_id,
        args.gateway_chain_id,
        args.gateway_rpc_url.clone(),
        args.l1_gas_price,
        args.refund_recipient,
    )
    .await
    .context("phase-1 submit stage")?;

    write_output_if_requested(
        "chain.gateway.migrate-to.phase-1-submit",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "gateway_chain_id": args.gateway_chain_id,
        }),
    )
    .await
}

// ── Phase 0: pause-deposits + notify-server ──────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase0PauseDepositsArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,
}

pub async fn run_phase0_pause_deposits(args: Phase0PauseDepositsArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    stage_pause_deposits(&mut runner, bridgehub, chain_id)
        .await
        .context("phase-0 pause-deposits stage")?;
    stage_notify_server(&mut runner, bridgehub, chain_id)
        .await
        .context("phase-0 notify-server stage")?;

    write_output_if_requested(
        "chain.gateway.migrate-to.phase-0-pause-deposits",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({ "chain_id": chain_id }),
    )
    .await
}

// ── Phase 2: finalize ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase2FinalizeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// Deployer EOA that finalizes the migration on L1.
    #[clap(long)]
    pub deployer_address: Address,

    /// Gateway L2 RPC URL (for querying the withdrawal proof and for
    /// the script's fork-switch to read the gateway CTM diamond cut data).
    #[clap(long)]
    pub gateway_rpc_url: String,

    /// Number of L1 blocks to scan back when searching for the
    /// MigrationStarted event. Default: ~30 days at 12s/block.
    #[clap(long, default_value = "216000")]
    pub lookback_blocks: u64,
}

pub async fn run_phase2_finalize(args: Phase2FinalizeArgs) -> anyhow::Result<()> {
    // Finalize has a special ordering constraint that the other phases
    // don't: the forge runner must be built *after* the gateway's migration
    // batch has settled on L1. In `--simulate`, `ForgeRunner::new` forks L1
    // at a single block height, so a fork created too early won't include
    // the batch's `chainBatchRoots` entry and the script reverts with
    // `InvalidProof()`. That's why the body is inlined here instead of
    // factored into a reusable `stage_finalize` helper shared with other
    // phases.
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let gateway_chain_id = crate::common::l1_contracts::resolve_settlement_layer(
        &args.shared.l1_rpc_url,
        bridgehub,
        chain_id,
    )
    .await
    .context("Failed to resolve gateway chain ID from bridgehub")?;
    logger::info(format!("Gateway chain ID (from L1): {gateway_chain_id}"));

    let gateway_diamond_proxy = crate::common::l1_contracts::resolve_zk_chain(
        &args.shared.l1_rpc_url,
        bridgehub,
        gateway_chain_id,
    )
    .await
    .context("Failed to resolve gateway diamond proxy")?;
    logger::info(format!(
        "Gateway diamond proxy (from L1): {:#x}",
        gateway_diamond_proxy
    ));

    // Step 1: Find the migration transaction on L1
    logger::step("Searching for migration transaction on L1");
    let l1_tx_hash = find_migration_tx(
        &args.shared.l1_rpc_url,
        bridgehub,
        chain_id,
        args.lookback_blocks,
    )
    .await
    .context("Failed to find migration transaction")?;
    logger::info(format!("Migration L1 tx: {:#x}", l1_tx_hash));

    // Step 2: Extract priority op hash from the L1 receipt
    let priority_op_hash =
        extract_priority_op_hash(&args.shared.l1_rpc_url, l1_tx_hash, gateway_diamond_proxy)
            .await
            .context("Failed to extract priority op hash from migration tx")?;
    logger::info(format!("Priority op L2 tx hash: {:#x}", priority_op_hash));

    // Step 3: Wait for the L2 tx to be finalized on the gateway
    logger::step("Waiting for migration tx to finalize on gateway");
    wait_for_l2_tx_receipt(&args.gateway_rpc_url, priority_op_hash)
        .await
        .context("Migration tx did not finalize on gateway")?;
    logger::info("Migration tx finalized on gateway");

    // Step 4: Get the L2->L1 log proof from the gateway (retry until batch is settled on L1)
    logger::step("Fetching L2->L1 log proof from gateway (waiting for batch settlement)");
    let proof = {
        let timeout = std::time::Duration::from_secs(300);
        let start = std::time::Instant::now();
        loop {
            match get_finalize_params(&args.gateway_rpc_url, priority_op_hash).await {
                Ok(p) => break p,
                Err(_) if start.elapsed() < timeout => {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
                Err(e) => return Err(e).context("Failed to get finalize migration params"),
            }
        }
    };
    logger::info(format!(
        "Proof: batch={}, messageIndex={}, txNumberInBatch={}",
        proof.batch_number, proof.l2_message_index, proof.l2_tx_number_in_batch
    ));

    // Construct the runner now, after the batch-settlement wait above —
    // see the block comment at the top of this function.
    let mut runner = ForgeRunner::new(&args.shared)?;
    // `finishMigrateChainToGateway` is caller-funded, not admin-gated —
    // use the caller-supplied deployer EOA so the Safe bundle target is a
    // signable address.
    let sender = runner.prepare_sender(args.deployer_address).await?;

    logger::step("Confirming L1->L2 transfer (finishMigrateChainToGateway)");
    {
        let merkle_proof = crate::common::ethereum::parse_merkle_proof(&proof.merkle_proof)?;
        let script = runner
            .with_script_call(
                &GATEWAY_UTILS_INVOCATION,
                "finishMigrateChainToGateway",
                (
                    bridgehub,
                    chain_id,
                    gateway_chain_id,
                    args.gateway_rpc_url.clone(),
                    priority_op_hash,
                    proof.batch_number,
                    proof.l2_message_index,
                    proof.l2_tx_number_in_batch,
                    merkle_proof,
                    1u8,
                ),
            )?
            .with_ffi()
            .with_wallet(&sender);
        runner
            .run(script)
            .context("finishMigrateChainToGateway failed")?;
    }

    write_output_if_requested(
        "chain.gateway.migrate-to.phase-2-finalize",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "gateway_chain_id": gateway_chain_id,
        }),
    )
    .await?;

    logger::success("Chain migration finalized (transfer confirmed)");
    Ok(())
}

// ── Phase 3: enable-validators + set-da-validator-pair ───────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Phase3ValidatorsArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// Gateway L2 RPC URL (for resolving ValidatorTimelock + chain diamond).
    #[clap(long)]
    pub gateway_rpc_url: String,

    /// Commit operator address.
    #[clap(long)]
    pub commit_operator: Address,

    /// Prove operator address.
    #[clap(long)]
    pub prove_operator: Address,

    /// Execute operator address.
    #[clap(long)]
    pub execute_operator: Address,

    /// Gateway ValidatorTimelock address on gateway L2.
    /// If not provided, resolved from the gateway RPC.
    #[clap(long)]
    pub gateway_validator_timelock: Option<Address>,

    /// L1 DA validator address (from vote preparation output).
    #[clap(long)]
    pub l1_da_validator: Address,

    /// L2 DA commitment scheme.
    #[clap(long, value_enum)]
    pub l2_da_commitment_scheme: L2DACommitmentScheme,

    /// L1 gas price in wei (default: 1 gwei).
    #[clap(long, default_value = "1000000000")]
    pub l1_gas_price: u64,
}

pub async fn run_phase3_validators(args: Phase3ValidatorsArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let enable_inputs = EnableValidatorsInputs {
        commit_operator: args.commit_operator,
        prove_operator: args.prove_operator,
        execute_operator: args.execute_operator,
        gateway_validator_timelock: args.gateway_validator_timelock,
        gateway_rpc_url: &args.gateway_rpc_url,
        l1_gas_price: args.l1_gas_price,
    };
    let (gateway_chain_id, n_validators) =
        stage_enable_validators(&mut runner, bridgehub, chain_id, &enable_inputs)
            .await
            .context("phase-3 enable-validators stage")?;

    let da_inputs = SetDaValidatorPairInputs {
        l1_da_validator: args.l1_da_validator,
        l2_da_commitment_scheme: args.l2_da_commitment_scheme,
        gateway_rpc_url: &args.gateway_rpc_url,
        l1_gas_price: args.l1_gas_price,
    };
    let (_gateway_chain_id, chain_diamond_on_gw) =
        stage_set_da_validator_pair(&mut runner, bridgehub, chain_id, &da_inputs)
            .await
            .context("phase-3 set-da-validator-pair stage")?;

    write_output_if_requested(
        "chain.gateway.migrate-to.phase-3-validators",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "gateway_chain_id": gateway_chain_id,
            "validators_enabled": n_validators,
            "l1_da_validator": format!("{:#x}", args.l1_da_validator),
            "chain_diamond_on_gateway": format!("{:#x}", chain_diamond_on_gw),
        }),
    )
    .await
}

pub async fn run_migrate_to(cmd: MigrateToCommands) -> anyhow::Result<()> {
    match cmd {
        MigrateToCommands::Phase0PauseDeposits(args) => run_phase0_pause_deposits(args).await,
        MigrateToCommands::Phase1Submit(args) => run_phase1_submit(args).await,
        MigrateToCommands::Phase2Finalize(args) => run_phase2_finalize(args).await,
        MigrateToCommands::Phase3Validators(args) => run_phase3_validators(args).await,
    }
}
