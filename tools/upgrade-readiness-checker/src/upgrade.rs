//! Locate the pending protocol upgrade transaction on the settlement layer and
//! compute its canonical hash.

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::{DynProvider, Provider};
use alloy::rpc::types::Filter;
use alloy::sol_types::{SolEvent, SolValue};
use anyhow::{anyhow, Context};
use tracing::{debug, info};

use crate::abi::{
    IBridgehub::IBridgehubInstance, IChainTypeManager::NewUpgradeCutData,
    ISettlementLayerUpgrade::ISettlementLayerUpgradeInstance, L2CanonicalTransaction,
};

/// How many settlement-layer blocks to scan per `eth_getLogs` request. Keeps us under
/// typical provider limits while still terminating in a reasonable number of round trips.
const MAX_BLOCKS_PER_QUERY: u64 = 50_000;

/// Resolve the chain's ChainTypeManager by calling `Bridgehub.chainTypeManager(chainId)`
/// on whatever layer the bridgehub lives on (L1 for direct chains, gateway for
/// gateway-settling chains).
pub async fn resolve_ctm(
    bridgehub_provider: &DynProvider,
    bridgehub_address: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let bridgehub = IBridgehubInstance::new(bridgehub_address, bridgehub_provider.clone());
    let ctm = bridgehub
        .chainTypeManager(U256::from(chain_id))
        .call()
        .await
        .context("Bridgehub.chainTypeManager call failed")?;
    if ctm == Address::ZERO {
        anyhow::bail!(
            "Bridgehub {bridgehub_address} returned zero address for chain {chain_id} — the chain is not registered on this layer"
        );
    }
    Ok(ctm)
}

/// Scan the settlement layer for the `NewUpgradeCutData` event matching
/// `protocol_version` and compute the canonical tx hash of the embedded
/// L2 upgrade transaction.
///
/// For v31+ upgrades, `SettlementLayerV31UpgradeBase.upgrade()` mutates
/// `l2ProtocolUpgradeTx.data` per-chain before hashing (to splice in
/// `ZKChainSpecificForceDeploymentsData` queried from the bridgehub/NTV). We
/// replicate that by calling the upgrade contract's `getL2UpgradeTxData` view
/// directly — single source of truth. Pre-v31 upgrade contracts don't expose
/// that selector; the eth_call reverts and we fall back to the unmutated data.
///
/// `lookback_blocks` caps how far back we scan; scans are performed newest-first
/// so recent upgrades are found quickly.
pub async fn find_upgrade_tx_hash(
    provider: &DynProvider,
    ctm_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
    zksync_os: bool,
    protocol_version: U256,
    lookback_blocks: u64,
) -> anyhow::Result<B256> {
    let latest = provider.get_block_number().await?;
    let start = latest.saturating_sub(lookback_blocks).max(1);

    let topic1 = B256::from(protocol_version.to_be_bytes::<32>());

    // Scan newest-first in chunks until we find the event (or exhaust the window).
    let mut to = latest;
    while to >= start {
        let from = to.saturating_sub(MAX_BLOCKS_PER_QUERY - 1).max(start);
        let filter = Filter::new()
            .address(ctm_address)
            .event_signature(NewUpgradeCutData::SIGNATURE_HASH)
            .topic1(topic1)
            .from_block(from)
            .to_block(to);

        let logs = provider
            .get_logs(&filter)
            .await
            .with_context(|| format!("eth_getLogs {from}..{to} for NewUpgradeCutData"))?;

        if let Some(log) = logs.last() {
            let decoded = log.log_decode::<NewUpgradeCutData>().context(
                "NewUpgradeCutData event decode failed — ABI mismatch with the deployed CTM",
            )?;
            let diamond_cut = decoded.inner.data.diamondCutData;
            return tx_hash_from_init_calldata(
                provider,
                diamond_cut.initAddress,
                bridgehub_address,
                chain_id,
                zksync_os,
                &diamond_cut.initCalldata,
            )
            .await;
        }

        if from == start {
            break;
        }
        to = from - 1;
    }

    Err(anyhow!(
        "No NewUpgradeCutData event for protocol version {protocol_version} on CTM {ctm_address} within the last {lookback_blocks} blocks (scanned {start}..{latest})",
    ))
}

/// Decode `ProposedUpgrade` from the DiamondCutData init calldata (the first 4 bytes
/// are the upgrade selector, the rest is `ProposedUpgrade` ABI-encoded), apply the
/// per-chain `.data` mutation performed by v31+ upgrade contracts, and compute
/// `keccak256(L2CanonicalTransaction.abi_encode())`.
async fn tx_hash_from_init_calldata(
    provider: &DynProvider,
    init_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
    zksync_os: bool,
    init_calldata: &[u8],
) -> anyhow::Result<B256> {
    if init_calldata.len() < 4 {
        anyhow::bail!("DiamondCutData.initCalldata too short ({} bytes)", init_calldata.len());
    }
    // Skip the 4-byte selector and decode the ProposedUpgrade struct.
    let proposed = <crate::abi::IChainTypeManager::ProposedUpgrade as SolValue>::abi_decode(
        &init_calldata[4..],
    )
    .context("ProposedUpgrade decode from initCalldata")?;

    let mut tx = proposed.l2ProtocolUpgradeTx;
    tx.data = rebuild_tx_data_if_v31plus(
        provider,
        init_address,
        bridgehub_address,
        chain_id,
        zksync_os,
        tx.data.clone(),
    )
    .await;

    Ok(canonical_tx_hash(&tx))
}

/// For v31+ upgrade contracts, call `initAddress.getL2UpgradeTxData(bridgehub, chainId,
/// originalData)` and return the rebuilt data. For pre-v31 contracts (or any other failure),
/// fall back to `original_data` — the older hashing path didn't mutate per-chain.
async fn rebuild_tx_data_if_v31plus(
    provider: &DynProvider,
    init_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
    zksync_os: bool,
    original_data: Bytes,
) -> Bytes {
    let upgrade = ISettlementLayerUpgradeInstance::new(init_address, provider.clone());
    match upgrade
        .getL2UpgradeTxData(
            bridgehub_address,
            U256::from(chain_id),
            zksync_os,
            original_data.clone(),
        )
        .call()
        .await
    {
        Ok(rebuilt) => {
            info!(
                %init_address,
                original_len = original_data.len(),
                rebuilt_len = rebuilt.len(),
                "applied v31+ per-chain tx-data mutation via getL2UpgradeTxData"
            );
            rebuilt
        }
        Err(err) => {
            // Pre-v31 upgrade contract, or selector genuinely missing — caller's hash
            // is computed from the original data, matching pre-v31 behavior.
            debug!(
                %init_address,
                error = %err,
                "getL2UpgradeTxData not available on upgrade contract; using original tx data"
            );
            original_data
        }
    }
}

/// The canonical L2 priority-op hash: `keccak256(abi_encode(L2CanonicalTransaction))`.
pub fn canonical_tx_hash(tx: &L2CanonicalTransaction) -> B256 {
    keccak256(tx.abi_encode())
}
