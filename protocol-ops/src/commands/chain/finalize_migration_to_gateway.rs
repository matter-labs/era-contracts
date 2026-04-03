use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::common::paths;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger,
    wallets::Wallet,
};

use super::migrate_to_gateway::VotePreparationOutput;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct FinalizeMigrationToGatewayArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Bridgehub proxy address.
    #[clap(long)]
    pub bridgehub_proxy_address: Address,

    /// Chain ID of the chain being migrated.
    #[clap(long)]
    pub chain_id: u64,

    /// Gateway chain ID (the settlement layer).
    #[clap(long)]
    pub gateway_chain_id: u64,

    /// Gateway L2 RPC URL (for querying finalization proofs).
    #[clap(long)]
    pub gateway_rpc_url: String,

    /// Gateway diamond proxy address (for filtering priority op events).
    #[clap(long)]
    pub gateway_diamond_proxy: Address,

    /// Path to the gateway vote preparation output TOML (for reading diamond_cut_data).
    #[clap(long, default_value = "/script-out/gateway-vote-preparation.toml")]
    pub vote_preparation_output_path: String,

    /// Commit operator address (to register on gateway ValidatorTimelock).
    #[clap(long)]
    pub commit_operator: Address,

    /// Prove operator address (to register on gateway ValidatorTimelock).
    #[clap(long)]
    pub prove_operator: Address,

    /// Execute operator address (to register on gateway ValidatorTimelock).
    #[clap(long)]
    pub execute_operator: Address,

    /// Gateway ValidatorTimelock address on gateway L2.
    /// If not provided, resolved from the gateway RPC.
    #[clap(long)]
    pub gateway_validator_timelock: Option<Address>,
}

pub async fn run(args: FinalizeMigrationToGatewayArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.shared.private_key, args.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::resolve_l1_contracts_path()?;

    // Read diamond_cut_data
    let output_path =
        contracts_path.join(args.vote_preparation_output_path.trim_start_matches('/'));
    let toml_content = std::fs::read_to_string(&output_path).with_context(|| {
        format!(
            "Failed to read vote preparation output: {}",
            output_path.display()
        )
    })?;
    let output: VotePreparationOutput =
        toml::from_str(&toml_content).context("Failed to parse vote preparation output")?;
    let diamond_cut_data_hex = format!("0x{}", output.diamond_cut_data.trim_start_matches("0x"));

    // Step 1: Find the migration transaction on L1
    logger::step("Searching for migration transaction on L1");
    let l1_tx_hash = find_migration_tx(
        &args.shared.l1_rpc_url,
        args.bridgehub_proxy_address,
        args.chain_id,
    )
    .await
    .context("Failed to find migration transaction")?;
    logger::info(format!("Migration L1 tx: {:#x}", l1_tx_hash));

    // Step 2: Extract priority op hash from the L1 receipt
    let priority_op_hash = extract_priority_op_hash(
        &args.shared.l1_rpc_url,
        l1_tx_hash,
        args.gateway_diamond_proxy,
    )
    .await
    .context("Failed to extract priority op hash from migration tx")?;
    logger::info(format!("Priority op L2 tx hash: {:#x}", priority_op_hash));

    // Step 3: Wait for the L2 tx to be finalized on the gateway
    logger::step("Waiting for migration tx to finalize on gateway");
    wait_for_l2_tx_receipt(&args.gateway_rpc_url, priority_op_hash)
        .await
        .context("Migration tx did not finalize on gateway")?;
    logger::info("Migration tx finalized on gateway");

    // Step 4: Get the L2→L1 log proof from the gateway (retry until batch is settled on L1)
    logger::step("Fetching L2→L1 log proof from gateway (waiting for batch settlement)");
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

    // Step 5: Build merkle proof array as a Solidity-compatible string
    let proof_str = format!(
        "[{}]",
        proof
            .merkle_proof
            .iter()
            .map(|h| format!("{}", h))
            .collect::<Vec<_>>()
            .join(",")
    );

    // Step 6a: Confirm the L1→L2 transfer via GatewayUtils.finishMigrateChainToGateway
    logger::step("Confirming L1→L2 transfer (finishMigrateChainToGateway)");
    {
        let mut sa = args.shared.forge_args.clone();
        sa.add_arg(ForgeScriptArg::Sig {
            sig: "finishMigrateChainToGateway(address,bytes,uint256,uint256,bytes32,uint256,uint256,uint16,bytes32[],uint8)".to_string(),
        });
        sa.add_arg(ForgeScriptArg::RpcUrl { url: runner.rpc_url.clone() });
        sa.add_arg(ForgeScriptArg::Broadcast);
        sa.add_arg(ForgeScriptArg::Ffi);
        sa.additional_args.extend([
            format!("{:#x}", args.bridgehub_proxy_address),
            diamond_cut_data_hex.clone(),
            args.chain_id.to_string(),
            args.gateway_chain_id.to_string(),
            format!("{:#x}", priority_op_hash),
            proof.batch_number.to_string(),
            proof.l2_message_index.to_string(),
            proof.l2_tx_number_in_batch.to_string(),
            proof_str,
            "1".to_string(), // TxStatus.Success
        ]);
        let script = Forge::new(&contracts_path)
            .script(Path::new("deploy-scripts/gateway/GatewayUtils.s.sol"), sa)
            .with_wallet(&sender, runner.simulate);
        runner.run(script).context("finishMigrateChainToGateway failed")?;
    }

    // Step 6b: Enable each validator on the gateway's ValidatorTimelock.
    // First, resolve the gateway's ValidatorTimelock address.
    logger::step("Resolving gateway ValidatorTimelock");
    let gw_validator_timelock = match args.gateway_validator_timelock {
        Some(addr) => addr,
        None => resolve_gateway_validator_timelock(
            &args.gateway_rpc_url,
            args.gateway_chain_id,
        )
        .await
        .context("Failed to resolve gateway ValidatorTimelock (pass --gateway-validator-timelock to skip RPC resolution)")?,
    };
    logger::info(format!("Gateway ValidatorTimelock: {:#x}", gw_validator_timelock));

    logger::step("Enabling validators on gateway");
    let validators: Vec<Address> = {
        let mut v = vec![args.commit_operator, args.prove_operator, args.execute_operator];
        v.sort();
        v.dedup();
        v.retain(|a| *a != Address::zero());
        v
    };
    for validator in &validators {
        logger::info(format!("Enabling validator {:#x}", validator));
        let mut sa = args.shared.forge_args.clone();
        sa.add_arg(ForgeScriptArg::Sig {
            sig: "enableValidatorViaGateway(address,uint256,uint256,uint256,address,address,address,bool)".to_string(),
        });
        sa.add_arg(ForgeScriptArg::RpcUrl { url: runner.rpc_url.clone() });
        sa.add_arg(ForgeScriptArg::Broadcast);
        sa.add_arg(ForgeScriptArg::Ffi);
        sa.additional_args.extend([
            format!("{:#x}", args.bridgehub_proxy_address),  // bridgehub
            "1000000000".to_string(),                         // l1GasPrice (1 gwei)
            args.chain_id.to_string(),                        // l2ChainId
            args.gateway_chain_id.to_string(),                // gatewayChainId
            format!("{:#x}", validator),                      // validatorAddress
            format!("{:#x}", gw_validator_timelock),           // gatewayValidatorTimelock
            format!("{:#x}", sender.address),                   // refundRecipient
            "true".to_string(),                               // _shouldSend
        ]);
        let script = Forge::new(&contracts_path)
            .script(Path::new("deploy-scripts/AdminFunctions.s.sol"), sa)
            .with_wallet(&sender, runner.simulate);
        runner.run(script).with_context(|| format!("enableValidatorViaGateway for {:#x}", validator))?;
    }

    logger::success("Chain migration finalized (transfer confirmed, validators enabled)");
    Ok(())
}

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Resolve the gateway's ValidatorTimelock address by querying the gateway L2 RPC.
/// The validator timelock lives on the gateway L2, so we must query the gateway's
/// Bridgehub (L2 system contract at 0x10002) → chainTypeManager → validatorTimelockPostV29.
async fn resolve_gateway_validator_timelock(
    gateway_rpc_url: &str,
    gateway_chain_id: u64,
) -> anyhow::Result<Address> {
    use ethers::providers::{Http, Middleware, Provider};

    let provider = Provider::<Http>::try_from(gateway_rpc_url)?;

    // Gateway L2 Bridgehub is at system address 0x10002
    let gw_bridgehub: Address = "0x0000000000000000000000000000000000010002".parse()?;

    // chainTypeManager(uint256) → address
    let ctm_call = ethers::abi::encode(&[ethers::abi::Token::Uint(gateway_chain_id.into())]);
    let mut calldata = ethers::utils::id("chainTypeManager(uint256)").to_vec();
    calldata.extend_from_slice(&ctm_call);
    let tx = ethers::types::TransactionRequest::new()
        .to(gw_bridgehub)
        .data(calldata);
    let result = provider
        .call(&tx.into(), None)
        .await
        .context("gateway L2 chainTypeManager call")?;
    let ctm = Address::from_slice(&result[12..32]);

    // validatorTimelockPostV29() → address
    let selector = ethers::utils::id("validatorTimelockPostV29()").to_vec();
    let tx2 = ethers::types::TransactionRequest::new()
        .to(ctm)
        .data(selector);
    let result = provider
        .call(&tx2.into(), None)
        .await
        .context("gateway L2 validatorTimelockPostV29 call")?;
    let timelock = Address::from_slice(&result[12..32]);

    Ok(timelock)
}

/// Find the migration transaction by scanning L1 for `MigrationStarted` events.
async fn find_migration_tx(
    l1_rpc_url: &str,
    _bridgehub_address: Address,
    chain_id: u64,
) -> anyhow::Result<ethers::types::H256> {
    use ethers::providers::{Http, Middleware, Provider};
    use ethers::types::Filter;

    let provider = Provider::<Http>::try_from(l1_rpc_url)?;
    let latest_block = provider.get_block_number().await?.as_u64();

    // MigrationStarted(uint256 indexed chainId, uint256 migrationNumber, bytes32 indexed assetId, uint256 indexed settlementLayerChainId)
    let topic0 = ethers::types::H256::from(ethers::utils::keccak256(
        b"MigrationStarted(uint256,uint256,bytes32,uint256)",
    ));
    let chain_id_topic = ethers::types::H256::from({
        let mut buf = [0u8; 32];
        buf[24..32].copy_from_slice(&chain_id.to_be_bytes());
        buf
    });

    let filter = Filter::new()
        .topic0(topic0)
        .topic1(chain_id_topic)
        .from_block(0u64)
        .to_block(latest_block);

    let logs = provider.get_logs(&filter).await.context(
        "Failed to query MigrationStarted events",
    )?;

    if let Some(log) = logs.last() {
        return log
            .transaction_hash
            .context("MigrationStarted event has no tx hash");
    }

    anyhow::bail!(
        "No MigrationStarted event found for chain {} in blocks 0..{}",
        chain_id,
        latest_block,
    )
}

/// Extract the first priority op hash from the migration L1 receipt.
async fn extract_priority_op_hash(
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

    // NewPriorityRequest topic0
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

/// Wait for an L2 transaction receipt on the gateway.
async fn wait_for_l2_tx_receipt(
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
        let resp = client.post(gateway_rpc_url).json(&body).send().await?;
        let json: serde_json::Value = resp.json().await?;
        if let Some(result) = json.get("result") {
            if !result.is_null() {
                return Ok(());
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
    tx_hash: ethers::types::H256,
) -> anyhow::Result<FinalizeParams> {
    let client = reqwest::Client::new();

    // First, find the L2→L1 log index for the bootloader (0x8001) sender
    let receipt_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getTransactionReceipt",
        "params": [format!("{:#x}", tx_hash)]
    });
    let resp = client
        .post(gateway_rpc_url)
        .json(&receipt_body)
        .send()
        .await?;
    let receipt_json: serde_json::Value = resp.json().await?;
    let receipt = receipt_json
        .get("result")
        .context("No receipt result")?;

    // Find the L2→L1 log from bootloader (address 0x8001)
    let l2_to_l1_logs = receipt
        .get("l2ToL1Logs")
        .and_then(|v| v.as_array())
        .context("No l2ToL1Logs in receipt")?;

    let bootloader = "0x0000000000000000000000000000000000008001";
    let mut log_index = None;
    let mut tx_number_in_batch = 0u16;
    for (i, log) in l2_to_l1_logs.iter().enumerate() {
        let sender = log
            .get("sender")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if sender.to_lowercase() == bootloader {
            log_index = Some(i);
            tx_number_in_batch = log
                .get("transactionIndex")
                .and_then(|v| v.as_str())
                .and_then(|s| u16::from_str_radix(s.trim_start_matches("0x"), 16).ok())
                .unwrap_or(0);
            break;
        }
    }
    let log_index =
        log_index.context("No L2→L1 log from bootloader (0x8001) in migration tx receipt")?;

    // Get the L2→L1 log proof
    let proof_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "zks_getL2ToL1LogProof",
        "params": [format!("{:#x}", tx_hash), log_index]
    });
    let resp = client
        .post(gateway_rpc_url)
        .json(&proof_body)
        .send()
        .await?;
    let proof_json: serde_json::Value = resp.json().await?;
    let proof = proof_json
        .get("result")
        .filter(|v| !v.is_null())
        .context("zks_getL2ToL1LogProof returned null")?;

    let batch_number = proof
        .get("batchNumber")
        .and_then(|v| v.as_u64())
        .context("missing batchNumber")?;
    let l2_message_index = proof
        .get("id")
        .and_then(|v| v.as_u64())
        .context("missing id")?;
    let merkle_proof: Vec<String> = proof
        .get("proof")
        .and_then(|v| v.as_array())
        .context("missing proof array")?
        .iter()
        .filter_map(|v| v.as_str().map(String::from))
        .collect();

    Ok(FinalizeParams {
        batch_number,
        l2_message_index,
        l2_tx_number_in_batch: tx_number_in_batch,
        merkle_proof,
    })
}
