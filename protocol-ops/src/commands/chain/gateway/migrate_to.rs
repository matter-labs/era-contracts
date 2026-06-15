use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};

use crate::common::abi::{AdminFunctionsAbi, GatewayUtilsAbi};
use crate::common::addresses::{GATEWAY_L2_BRIDGEHUB, L2_BOOTLOADER};
use crate::common::forge::scripts::{ADMIN_FUNCTIONS_INVOCATION, GATEWAY_UTILS_INVOCATION};
use crate::common::output::write_output_if_requested;
use crate::common::EcosystemChainArgs;
use crate::common::SharedRunArgs;
use crate::common::{forge::ForgeRunner, logger};

use crate::types::L2DACommitmentScheme;

/// Default number of L1 blocks to scan backwards when searching for the chain
/// migration transaction submitted during phase-1.  At ~12 s/block this covers
/// roughly 30 days — ample time for a migration that was submitted but not yet
/// finalized.
pub const DEFAULT_FINALIZE_LOOKBACK_BLOCKS: u64 = 216_000;

/// View of the vote preparation output TOML produced by `convert vote-prepare`.
#[derive(Debug, Deserialize)]
pub struct VotePreparationOutput {
    pub diamond_cut_data: String,
    /// Address of the RelayedSLDAValidator deployed on L1 during vote preparation.
    /// Used by phase-3 to set the DA validator pair on the gateway.
    pub relayed_sl_da_validator: Option<String>,
}

/// Typed return value of [`finalize_migration`].
///
/// Returned alongside the `ForgeRunner` so callers own output-writing and
/// state management, keeping `finalize_migration` free of manifest side-effects.
pub struct FinalizeResult {
    pub gateway_chain_id: u64,
}

/// Input parameters for [`finalize_migration`].
pub struct FinalizeMigrationArgs<'a> {
    pub shared: &'a SharedRunArgs,
    pub bridgehub: Address,
    pub chain_id: u64,
    pub deployer_address: Address,
    pub gateway_rpc_url: &'a str,
    pub lookback_blocks: u64,
    pub priority_op_hash_hint: Option<B256>,
}

// ── Step 1: Pause deposits ------------------------------------------------

/// Run the `pause-deposits` stage against an existing `runner` fork.
/// Reusable from phase-0-pause-deposits.
pub async fn stage_pause_deposits(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    // Always broadcast the admin call, including in `--simulate`. The simulate
    // fork is ephemeral, but the Safe bundle is built from forge's broadcast
    // log, so the admin tx must be in there for downstream replay.
    let script = runner
        .script_with_calldata(
            &ADMIN_FUNCTIONS_INVOCATION,
            AdminFunctionsAbi::pauseDepositsBeforeInitiatingMigrationCall {
                _bridgehub: bridgehub,
                _chainId: U256::from(chain_id),
                _shouldSend: true,
            }
            .abi_encode(),
        )
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
pub async fn stage_notify_server(
    runner: &mut ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;

    // See pause-deposits for the rationale — always broadcast in simulate too
    // so the tx shows up in the bundle's --out / Safe file.
    let script = runner
        .script_with_calldata(
            &ADMIN_FUNCTIONS_INVOCATION,
            AdminFunctionsAbi::notifyServerMigrationToGatewayCall {
                _bridgehub: bridgehub,
                _chainId: U256::from(chain_id),
                _shouldSend: true,
            }
            .abi_encode(),
        )
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
pub async fn stage_submit(
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
        .script_with_calldata(
            &ADMIN_FUNCTIONS_INVOCATION,
            AdminFunctionsAbi::migrateChainToGatewayCall {
                _bridgehub: bridgehub,
                _l1GasPrice: U256::from(l1_gas_price),
                _l2ChainId: U256::from(chain_id),
                _gatewayChainId: U256::from(gateway_chain_id),
                _gatewayRpcUrl: gateway_rpc_url,
                _refundRecipient: refund_recipient,
                _shouldSend: true,
            }
            .abi_encode(),
        )
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
pub struct EnableValidatorsInputs<'a> {
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
pub async fn stage_enable_validators(
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
        v.retain(|a| *a != Address::ZERO);
        v
    };

    logger::step("Enabling validators on gateway");
    for validator in &validators {
        logger::info(format!("Enabling validator {:#x}", validator));
        let script = runner
            .script_with_calldata(
                &ADMIN_FUNCTIONS_INVOCATION,
                AdminFunctionsAbi::enableValidatorViaGatewayCall {
                    _bridgehub: bridgehub,
                    _l1GasPrice: U256::from(inputs.l1_gas_price),
                    _l2ChainId: U256::from(chain_id),
                    _gatewayChainId: U256::from(gateway_chain_id),
                    _validatorAddress: *validator,
                    _gatewayValidatorTimelock: gw_validator_timelock,
                    _refundRecipient: sender.address,
                    _shouldSend: true,
                }
                .abi_encode(),
            )
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
pub struct SetDaValidatorPairInputs<'a> {
    pub l1_da_validator: Address,
    pub l2_da_commitment_scheme: L2DACommitmentScheme,
    pub gateway_rpc_url: &'a str,
    pub l1_gas_price: u64,
}

/// Run the `set-da-validator-pair` stage. Returns
/// `(gateway_chain_id, chain_diamond_on_gateway)`.
pub async fn stage_set_da_validator_pair(
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
        .script_with_calldata(
            &ADMIN_FUNCTIONS_INVOCATION,
            AdminFunctionsAbi::setDAValidatorPairWithGatewayCall {
                _bridgehub: bridgehub,
                _l1GasPrice: U256::from(inputs.l1_gas_price),
                _l2ChainId: U256::from(chain_id),
                _gatewayChainId: U256::from(gateway_chain_id),
                _l1DAValidator: inputs.l1_da_validator,
                _l2DACommitmentScheme: inputs.l2_da_commitment_scheme as u8,
                _chainDiamondProxyOnGateway: chain_diamond_on_gw,
                _refundRecipient: sender.address,
                _shouldSend: true,
            }
            .abi_encode(),
        )
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
    use crate::common::abi::BridgehubAbi;
    use crate::common::ethereum::get_provider;

    let provider = get_provider(gateway_rpc_url)?;
    let gw_bridgehub: Address = GATEWAY_L2_BRIDGEHUB.parse()?;
    let bh = BridgehubAbi::new(gw_bridgehub, provider);
    let addr = bh
        .getZKChain(U256::from(chain_id))
        .call()
        .await
        .context("gateway L2 getZKChain call")?;
    anyhow::ensure!(
        addr != Address::ZERO,
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
    use crate::common::abi::{BridgehubAbi, IChainTypeManagerAbi};
    use crate::common::ethereum::get_provider;

    let provider = get_provider(gateway_rpc_url)?;
    let gw_bridgehub: Address = GATEWAY_L2_BRIDGEHUB.parse()?;
    let bh = BridgehubAbi::new(gw_bridgehub, provider.clone());

    let ctm = bh
        .chainTypeManager(U256::from(chain_id))
        .call()
        .await
        .context("gateway L2 chainTypeManager call")?;
    anyhow::ensure!(
        ctm != Address::ZERO,
        "gateway L2 bridgehub.chainTypeManager({chain_id}) returned zero — \
         chain not registered on the gateway. \
         Ensure migration finalize (phase 2) has completed before enable-validators (phase 3)."
    );
    logger::info(format!("Gateway L2 CTM (from chain {chain_id}): {ctm:#x}"));

    let ctm_contract = IChainTypeManagerAbi::new(ctm, provider);
    let timelock = ctm_contract
        .validatorTimelockPostV29()
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
) -> anyhow::Result<B256> {
    use crate::common::ethereum::get_provider;
    use alloy::primitives::{keccak256, U256};
    use alloy::providers::Provider;
    use alloy::rpc::types::Filter;

    let provider = get_provider(l1_rpc_url)?;

    // Resolve the chainAssetHandler from the bridgehub — that's where
    // MigrationStarted is emitted.
    let bridgehub = crate::common::abi::BridgehubAbi::new(bridgehub_address, provider.clone());
    let chain_asset_handler: Address = bridgehub
        .chainAssetHandler()
        .call()
        .await
        .context("Failed to read chainAssetHandler from bridgehub")?;

    let latest_block = provider.get_block_number().await?;
    let from_block = latest_block.saturating_sub(lookback_blocks);

    let topic0 = keccak256(b"MigrationStarted(uint256,uint256,bytes32,uint256)");
    let chain_id_topic = B256::from(U256::from(chain_id).to_be_bytes::<32>());

    let filter = Filter::new()
        .address(chain_asset_handler)
        .event_signature(topic0)
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
    tx_hash: B256,
    gateway_diamond_proxy: Address,
) -> anyhow::Result<B256> {
    use crate::common::ethereum::get_provider;
    use alloy::primitives::keccak256;
    use alloy::providers::Provider;

    let provider = get_provider(l1_rpc_url)?;
    let receipt = provider
        .get_transaction_receipt(tx_hash)
        .await?
        .context("Migration tx receipt not found")?;

    let topic0 = keccak256(
        b"NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])",
    );

    for log in receipt.inner.logs() {
        if log.topics().first() == Some(&topic0)
            && log.address() == gateway_diamond_proxy
            && log.data().data.len() >= 64
        {
            return Ok(B256::from_slice(&log.data().data[32..64]));
        }
    }

    anyhow::bail!(
        "No NewPriorityRequest log found from gateway diamond proxy {:#x} in tx {:#x}",
        gateway_diamond_proxy,
        tx_hash,
    )
}

// ── RPC response types for ZKSync-specific methods ────────────────────────

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

fn gateway_provider(rpc_url: &str) -> anyhow::Result<crate::common::ethereum::AlloyProvider> {
    crate::common::ethereum::get_provider(rpc_url)
}

// ── RPC helpers ───────────────────────────────────────────────────────────

/// Wait for an L2 transaction receipt on the gateway.
///
/// Uses `raw_request` with a minimal struct to avoid alloy's typed receipt
/// deserialization, which fails on ZKsync-specific transaction types (e.g.
/// `0x7f` for L1→L2 priority transactions).
///
/// Returns the L2 block number the tx was included in so callers can wait for
/// that block to be finalized on L1 before building finalization proofs.
pub(super) async fn wait_for_l2_tx_receipt(
    gateway_rpc_url: &str,
    tx_hash: B256,
) -> anyhow::Result<u64> {
    #[derive(Debug, serde::Deserialize)]
    struct MinimalReceipt {
        status: Option<String>,
        #[serde(rename = "blockNumber")]
        block_number: Option<String>,
    }

    let provider = gateway_provider(gateway_rpc_url)?;
    let timeout = std::time::Duration::from_secs(300);
    let start = std::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            anyhow::bail!("Timed out waiting for L2 tx {:#x} on gateway", tx_hash);
        }

        let receipt: Option<MinimalReceipt> = provider
            .raw_request(
                "eth_getTransactionReceipt".into(),
                (format!("{:#x}", tx_hash),),
            )
            .await
            .context("eth_getTransactionReceipt")?;

        if let Some(r) = receipt {
            if r.status.as_deref() == Some("0x0") {
                anyhow::bail!(
                    "Migration priority tx {:#x} reverted on gateway (status=0x0). \
                     Check gateway logs for the revert reason.",
                    tx_hash
                );
            }
            let block_number = r
                .block_number
                .as_deref()
                .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
                .unwrap_or(0);
            return Ok(block_number);
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

/// Wait until the gateway L2's "finalized" block (i.e. the highest block whose
/// containing batch has been executed on L1) reaches or exceeds `target_block`.
///
/// This is required before calling `zks_getL2ToL1LogProof` to build the proof
/// for `finishMigrateChainToGateway`.  The proof is verified against
/// `L1MessageRoot`, which only stores a batch root after the gateway batch has
/// been **executed** on L1 (not just committed or proved).  Fetching the proof
/// and calling `finishMigrateChainToGateway` before the batch is executed
/// causes `proveL1ToL2TransactionStatusShared` to return `InvalidProof`.
async fn wait_for_gateway_block_finalized(
    gateway_rpc_url: &str,
    target_block: u64,
) -> anyhow::Result<()> {
    #[derive(Debug, serde::Deserialize)]
    struct BlockResult {
        number: Option<String>,
    }

    let provider = gateway_provider(gateway_rpc_url)?;
    let timeout = std::time::Duration::from_secs(300);
    let start = std::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            anyhow::bail!(
                "Timed out waiting for gateway finalized block to reach {} \
                 (needed for L1MessageRoot batch root inclusion)",
                target_block
            );
        }

        let result: Option<BlockResult> = provider
            .raw_request("eth_getBlockByNumber".into(), ("finalized", false))
            .await
            .unwrap_or(None);

        if let Some(block) = result {
            if let Some(num_str) = block.number {
                if let Ok(num) = u64::from_str_radix(num_str.trim_start_matches("0x"), 16) {
                    if num >= target_block {
                        return Ok(());
                    }
                }
            }
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
    tx_hash: B256,
) -> anyhow::Result<FinalizeParams> {
    let provider = gateway_provider(gateway_rpc_url)?;

    // Fetch the ZKSync-specific transaction receipt (includes l2ToL1Logs)
    // to find the bootloader L2->L1 log. Fetched as a raw JSON value first so
    // the full receipt can be dumped for debugging before typed parsing.
    let receipt_raw: serde_json::Value = provider
        .raw_request(
            "eth_getTransactionReceipt".into(),
            (format!("{:#x}", tx_hash),),
        )
        .await
        .context("eth_getTransactionReceipt")?;
    eprintln!(
        "[debug get_finalize_params] raw receipt for {tx_hash:#x}: {}",
        serde_json::to_string_pretty(&receipt_raw).unwrap_or_default()
    );
    anyhow::ensure!(
        !receipt_raw.is_null(),
        "eth_getTransactionReceipt returned null"
    );
    let receipt: GatewayTransactionReceipt =
        serde_json::from_value(receipt_raw).context("Failed to parse gateway receipt")?;

    // The **bootloader** (`0x8001`) emits a system L2→L1 log for every L1→L2
    // priority transaction confirming its execution status. This is the log
    // that `proveL1ToL2TransactionStatusShared` /
    // `MessageHashing.getL2LogFromL1ToL2Transaction` verifies in
    // `bridgeConfirmTransferResult` — NOT a message from L1Messenger
    // (`0x8008`). Migration priority txs do not call `sendToL1()` directly,
    // so looking for L1Messenger logs would always fail.
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

    // Fetch the L2->L1 log proof via the ZKSync-specific method. Fetched raw
    // first so the response can be dumped for debugging before typed parsing.
    let proof_raw: serde_json::Value = provider
        .raw_request(
            "zks_getL2ToL1LogProof".into(),
            (format!("{:#x}", tx_hash), log_index),
        )
        .await
        .context("zks_getL2ToL1LogProof")?;
    eprintln!(
        "[debug get_finalize_params] zks_getL2ToL1LogProof(tx={tx_hash:#x}, log_index={log_index}) → {}",
        serde_json::to_string_pretty(&proof_raw).unwrap_or_default()
    );
    eprintln!(
        "[debug get_finalize_params] tx_number_in_batch={tx_number_in_batch}, log_index={log_index}",
    );
    anyhow::ensure!(!proof_raw.is_null(), "zks_getL2ToL1LogProof returned null");
    let proof: L2ToL1LogProof = serde_json::from_value(proof_raw)
        .context("Failed to parse zks_getL2ToL1LogProof response")?;

    Ok(FinalizeParams {
        batch_number: proof.batch_number,
        l2_message_index: proof.id,
        l2_tx_number_in_batch: tx_number_in_batch,
        merkle_proof: proof.proof,
    })
}

/// Capture the priority op hash immediately after a phase-1 broadcast.
///
/// Scans the last 100 L1 blocks (≈ 20 minutes at 12 s/block) for the
/// `MigrationStarted` event, then extracts the `NewPriorityRequest` hash
/// from the transaction receipt. Called right after `apply_manifest_from`
/// completes so the tx is only a few blocks old and the short lookback is
/// sufficient.
///
/// Returned value is stored in `GatewayMigratePhase1Output` so phase-2 can
/// skip the full 216k-block lookback entirely.
pub async fn capture_priority_op_hash_after_submit(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
    gateway_chain_id: u64,
) -> anyhow::Result<B256> {
    const SHORT_LOOKBACK_BLOCKS: u64 = 100;

    let l1_tx_hash = find_migration_tx(l1_rpc_url, bridgehub, chain_id, SHORT_LOOKBACK_BLOCKS)
        .await
        .context("finding MigrationStarted event after phase-1 broadcast")?;

    let gateway_diamond_proxy =
        crate::common::l1_contracts::resolve_zk_chain(l1_rpc_url, bridgehub, gateway_chain_id)
            .await
            .context("resolving gateway diamond proxy for priority op extraction")?;

    extract_priority_op_hash(l1_rpc_url, l1_tx_hash, gateway_diamond_proxy)
        .await
        .context("extracting priority op hash from migration tx receipt")
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
    let (bridgehub, chain_id) = args.topology.resolve()?;
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
    let (bridgehub, chain_id) = args.topology.resolve()?;
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
    #[clap(long, default_value_t = DEFAULT_FINALIZE_LOOKBACK_BLOCKS)]
    pub lookback_blocks: u64,
}

/// Phase-2 finalize: wait for the gateway to execute and settle the migration
/// priority tx, then call `finishMigrateChainToGateway` on L1.
///
/// Returns the forge runner (needed for bundle writing) and a typed
/// [`FinalizeResult`]. Callers own all output-writing and state management.
///
/// The runner is created *after* the gateway batch-settlement wait — this is
/// the key ordering constraint: a fork taken too early won't include the
/// batch's `chainBatchRoots` entry and the script reverts with `InvalidProof`.
///
/// If `priority_op_hash_hint` is `Some`, the L1 event scan and gateway diamond
/// proxy resolution are skipped and the provided hash is used directly. Pass
/// the value saved in `GatewayMigratePhase1Output` from the `apply` workflow
/// to avoid a 216k-block L1 lookback.
pub async fn finalize_migration(
    args: FinalizeMigrationArgs<'_>,
) -> anyhow::Result<(ForgeRunner, FinalizeResult)> {
    let FinalizeMigrationArgs {
        shared,
        bridgehub,
        chain_id,
        deployer_address,
        gateway_rpc_url,
        lookback_blocks,
        priority_op_hash_hint,
    } = args;
    let gateway_chain_id = crate::common::l1_contracts::resolve_settlement_layer(
        &shared.l1_rpc_url,
        bridgehub,
        chain_id,
    )
    .await
    .context("Failed to resolve gateway chain ID from bridgehub")?;
    logger::info(format!("Gateway chain ID (from L1): {gateway_chain_id}"));

    // Resolve the priority op hash: use the cached value from phase-1 state
    // when available (apply workflow) to skip the expensive L1 event scan.
    let priority_op_hash = match priority_op_hash_hint {
        Some(h) => {
            logger::info(format!("Using priority op hash from phase-1 state: {h:#x}"));
            h
        }
        None => {
            let gateway_diamond_proxy = crate::common::l1_contracts::resolve_zk_chain(
                &shared.l1_rpc_url,
                bridgehub,
                gateway_chain_id,
            )
            .await
            .context("Failed to resolve gateway diamond proxy")?;
            logger::info(format!(
                "Gateway diamond proxy (from L1): {:#x}",
                gateway_diamond_proxy
            ));

            logger::step("Searching for migration transaction on L1");
            let l1_tx_hash =
                find_migration_tx(&shared.l1_rpc_url, bridgehub, chain_id, lookback_blocks)
                    .await
                    .context("Failed to find migration transaction")?;
            logger::info(format!("Migration L1 tx: {:#x}", l1_tx_hash));

            extract_priority_op_hash(&shared.l1_rpc_url, l1_tx_hash, gateway_diamond_proxy)
                .await
                .context("Failed to extract priority op hash from migration tx")?
        }
    };
    logger::info(format!("Priority op L2 tx hash: {:#x}", priority_op_hash));

    logger::step("Waiting for migration tx to finalize on gateway");
    let tx_block = wait_for_l2_tx_receipt(gateway_rpc_url, priority_op_hash)
        .await
        .context("Migration tx did not finalize on gateway")?;
    logger::info(format!(
        "Migration tx included in gateway L2 block {}",
        tx_block
    ));

    // Wait for the gateway to fully execute the block on L1 (commit → prove → execute).
    // `L1MessageRoot.chainBatchRoots[gatewayChainId][batchNumber]` is populated only
    // during the *execute* step.  Fetching the proof before then causes
    // `proveL1ToL2TransactionStatusShared` to return `InvalidProof`.
    logger::step(format!(
        "Waiting for gateway block {} to be finalized on L1 (L1MessageRoot update)...",
        tx_block
    ));
    wait_for_gateway_block_finalized(gateway_rpc_url, tx_block)
        .await
        .context("Gateway block did not reach finalized status in time")?;
    logger::info("Gateway block finalized on L1");

    logger::step("Fetching L2->L1 log proof from gateway (waiting for batch settlement)");
    let proof = {
        let timeout = std::time::Duration::from_secs(300);
        let start = std::time::Instant::now();
        loop {
            match get_finalize_params(gateway_rpc_url, priority_op_hash).await {
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

    // Construct the runner now, after the batch-settlement wait above.
    let mut runner = ForgeRunner::new(shared)?;
    // `finishMigrateChainToGateway` is caller-funded, not admin-gated —
    // use the caller-supplied deployer EOA so the Safe bundle target is a
    // signable address.
    let sender = runner.prepare_sender(deployer_address).await?;

    logger::step("Confirming L1->L2 transfer (finishMigrateChainToGateway)");
    {
        let merkle_proof = crate::common::ethereum::parse_merkle_proof(&proof.merkle_proof)?;
        let script = runner
            .script_with_calldata(
                &GATEWAY_UTILS_INVOCATION,
                GatewayUtilsAbi::finishMigrateChainToGatewayCall {
                    params: GatewayUtilsAbi::FinishMigrateChainToGatewayParams {
                        bridgehubAddr: bridgehub,
                        l2TxNumberInBatch: proof.l2_tx_number_in_batch,
                        txStatus: 1,
                        l2TxHash: priority_op_hash,
                        migratingChainId: U256::from(chain_id),
                        gatewayChainId: U256::from(gateway_chain_id),
                        l2BatchNumber: U256::from(proof.batch_number),
                        l2MessageIndex: U256::from(proof.l2_message_index),
                        gatewayRpcUrl: gateway_rpc_url.to_string(),
                        merkleProof: merkle_proof,
                    },
                }
                .abi_encode(),
            )
            .with_ffi()
            .with_wallet(&sender);
        runner
            .run(script)
            .context("finishMigrateChainToGateway failed")?;
    }

    logger::success("Chain migration finalized (transfer confirmed)");
    Ok((runner, FinalizeResult { gateway_chain_id }))
}

pub async fn run_phase2_finalize(args: Phase2FinalizeArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let (runner, result) = finalize_migration(FinalizeMigrationArgs {
        shared: &args.shared,
        bridgehub,
        chain_id,
        deployer_address: args.deployer_address,
        gateway_rpc_url: &args.gateway_rpc_url,
        lookback_blocks: args.lookback_blocks,
        priority_op_hash_hint: None,
    })
    .await?;
    write_output_if_requested(
        "chain.gateway.migrate-to.phase-2-finalize",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "chain_id": chain_id,
            "gateway_chain_id": result.gateway_chain_id,
        }),
    )
    .await
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
    let (bridgehub, chain_id) = args.topology.resolve()?;
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
