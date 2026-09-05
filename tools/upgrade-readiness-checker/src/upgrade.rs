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
    ILegacySettlementLayerUpgrade::ILegacySettlementLayerUpgradeInstance,
    ISettlementLayerUpgrade::ISettlementLayerUpgradeInstance, L2CanonicalTransaction,
};

/// How many settlement-layer blocks to scan per `eth_getLogs` request. Keeps us under
/// typical provider limits while still terminating in a reasonable number of round trips.
const MAX_BLOCKS_PER_QUERY: u64 = 50_000;

/// Bit offset of the minor component in the packed protocol version.
const PACKED_SEMVER_MINOR_OFFSET: usize = 32;

/// First protocol minor whose upgrade transaction data is rewritten per chain.
const FIRST_PER_CHAIN_REWRITE_PROTOCOL_MINOR: u64 = 31;

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
/// For v31+ upgrades, the upgrade contract mutates `l2ProtocolUpgradeTx.data`
/// per-chain before hashing (to splice in `ZKChainSpecificForceDeploymentsData`
/// queried from the bridgehub/NTV). We replicate that by calling the upgrade
/// contract's `getL2UpgradeTxData` view directly — single source of truth. The
/// current three-argument ABI is tried first, followed by the legacy four-argument
/// ABI. Pre-v31 upgrades did not mutate the data and use it unchanged.
///
/// `lookback_blocks` caps how far back we scan; scans are performed newest-first
/// so recent upgrades are found quickly.
pub async fn find_upgrade_tx_hash(
    provider: &DynProvider,
    ctm_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
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
                protocol_version,
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
    protocol_version: U256,
    init_calldata: &[u8],
) -> anyhow::Result<B256> {
    if init_calldata.len() < 4 {
        anyhow::bail!(
            "DiamondCutData.initCalldata too short ({} bytes)",
            init_calldata.len()
        );
    }
    // Skip the 4-byte selector and decode the ProposedUpgrade struct.
    let proposed = <crate::abi::IChainTypeManager::ProposedUpgrade as SolValue>::abi_decode(
        &init_calldata[4..],
    )
    .context("ProposedUpgrade decode from initCalldata")?;

    let mut tx = proposed.l2ProtocolUpgradeTx;
    if tx.txType == U256::ZERO {
        anyhow::bail!(
            "upgrade has no L2 protocol transaction (txType is zero); receipt-based readiness does not apply"
        );
    }
    tx.data = rebuild_tx_data_if_v31plus(
        provider,
        init_address,
        bridgehub_address,
        chain_id,
        protocol_version,
        tx.data.clone(),
    )
    .await?;

    Ok(canonical_tx_hash(&tx))
}

/// For v31+ upgrade contracts, return the per-chain transaction data produced by the
/// current rewrite ABI, falling back to the legacy ABI used by already-published upgrades.
/// Pre-v31 upgrades did not rewrite the transaction data. A failure of both v31+ ABIs is
/// fatal: silently hashing the placeholder data would make the checker wait for a transaction
/// that can never exist.
async fn rebuild_tx_data_if_v31plus(
    provider: &DynProvider,
    init_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
    protocol_version: U256,
    original_data: Bytes,
) -> anyhow::Result<Bytes> {
    let protocol_minor = (protocol_version >> PACKED_SEMVER_MINOR_OFFSET) & U256::from(u32::MAX);
    if protocol_minor < U256::from(FIRST_PER_CHAIN_REWRITE_PROTOCOL_MINOR) {
        return Ok(original_data);
    }

    let upgrade = ISettlementLayerUpgradeInstance::new(init_address, provider.clone());
    match upgrade
        .getL2UpgradeTxData(
            bridgehub_address,
            U256::from(chain_id),
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
                "applied per-chain tx-data mutation via current getL2UpgradeTxData ABI"
            );
            Ok(rebuilt)
        }
        Err(current_err) => {
            debug!(
                %init_address,
                error = %current_err,
                "current getL2UpgradeTxData ABI failed; trying legacy ABI"
            );

            let legacy_upgrade =
                ILegacySettlementLayerUpgradeInstance::new(init_address, provider.clone());
            match legacy_upgrade
                .getL2UpgradeTxData(
                    bridgehub_address,
                    U256::from(chain_id),
                    true,
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
                        "applied per-chain tx-data mutation via legacy getL2UpgradeTxData ABI"
                    );
                    Ok(rebuilt)
                }
                Err(legacy_err) => Err(anyhow!(
                    "getL2UpgradeTxData failed with both current and legacy ABIs on v31+ upgrade contract {init_address}: current ABI: {current_err}; legacy ABI: {legacy_err}"
                )),
            }
        }
    }
}

/// The canonical L2 priority-op hash: `keccak256(abi_encode(L2CanonicalTransaction))`.
pub fn canonical_tx_hash(tx: &L2CanonicalTransaction) -> B256 {
    keccak256(tx.abi_encode())
}

#[cfg(test)]
mod tests {
    use super::*;

    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolCall;
    use alloy::transports::mock::Asserter;

    use crate::abi::{
        ILegacySettlementLayerUpgrade::getL2UpgradeTxDataCall as LegacyGetL2UpgradeTxDataCall,
        ISettlementLayerUpgrade::getL2UpgradeTxDataCall as CurrentGetL2UpgradeTxDataCall,
    };

    fn protocol_version(minor: u64) -> U256 {
        // Keep both adjacent SemVer lanes nonzero so the tests also pin extraction to the
        // 32-bit minor component rather than accepting an unmasked right shift.
        (U256::from(1_u64) << 64)
            | (U256::from(minor) << PACKED_SEMVER_MINOR_OFFSET)
            | U256::from(9_u64)
    }

    fn push_rewrite_success(asserter: &Asserter, rewritten: &Bytes) {
        let encoded_return =
            Bytes::from(CurrentGetL2UpgradeTxDataCall::abi_encode_returns(rewritten));
        asserter.push_success(&encoded_return);
    }

    #[tokio::test]
    async fn rewrite_uses_current_abi_when_available() {
        assert_eq!(
            CurrentGetL2UpgradeTxDataCall::SELECTOR,
            [0xb1, 0x70, 0x1f, 0xb0]
        );

        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let original = Bytes::from_static(b"placeholder");
        let rewritten = Bytes::from_static(b"current");
        push_rewrite_success(&asserter, &rewritten);

        let actual = rebuild_tx_data_if_v31plus(
            &provider,
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            270,
            protocol_version(31),
            original,
        )
        .await
        .unwrap();

        assert_eq!(actual, rewritten);
        assert!(
            asserter.read_q().is_empty(),
            "current ABI should be called exactly once"
        );
    }

    #[tokio::test]
    async fn rewrite_falls_back_to_legacy_abi() {
        assert_eq!(
            LegacyGetL2UpgradeTxDataCall::SELECTOR,
            [0x1c, 0x98, 0x76, 0xff]
        );

        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let original = Bytes::from_static(b"placeholder");
        let rewritten = Bytes::from_static(b"legacy");
        asserter.push_failure_msg("current selector missing");
        push_rewrite_success(&asserter, &rewritten);

        let actual = rebuild_tx_data_if_v31plus(
            &provider,
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            270,
            protocol_version(31),
            original,
        )
        .await
        .unwrap();

        assert_eq!(actual, rewritten);
        assert!(
            asserter.read_q().is_empty(),
            "current failure and legacy success should consume exactly two calls"
        );
    }

    #[tokio::test]
    async fn rewrite_fails_when_both_abis_fail() {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        asserter.push_failure_msg("current call failed");
        asserter.push_failure_msg("legacy call failed");

        let err = rebuild_tx_data_if_v31plus(
            &provider,
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            270,
            protocol_version(31),
            Bytes::from_static(b"placeholder"),
        )
        .await
        .unwrap_err();

        let message = err.to_string();
        assert!(message.contains("both current and legacy ABIs"));
        assert!(message.contains("current call failed"));
        assert!(message.contains("legacy call failed"));
        assert!(
            asserter.read_q().is_empty(),
            "dual failure should consume the current and legacy responses in order"
        );
    }

    #[tokio::test]
    async fn pre_v31_upgrade_uses_original_data_without_calling() {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let original = Bytes::from_static(b"unchanged");

        let actual = rebuild_tx_data_if_v31plus(
            &provider,
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            270,
            protocol_version(30),
            original.clone(),
        )
        .await
        .unwrap();

        assert_eq!(actual, original);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn verifier_only_upgrade_fails_with_explicit_diagnostic() {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let proposed = crate::abi::IChainTypeManager::ProposedUpgrade {
            l2ProtocolUpgradeTx: L2CanonicalTransaction {
                txType: U256::ZERO,
                from: U256::ZERO,
                to: U256::ZERO,
                gasLimit: U256::ZERO,
                gasPerPubdataByteLimit: U256::ZERO,
                maxFeePerGas: U256::ZERO,
                maxPriorityFeePerGas: U256::ZERO,
                paymaster: U256::ZERO,
                nonce: U256::ZERO,
                value: U256::ZERO,
                reserved: [U256::ZERO; 4],
                data: Bytes::new(),
                signature: Bytes::new(),
                factoryDeps: Vec::new(),
                paymasterInput: Bytes::new(),
                reservedDynamic: Bytes::new(),
            },
            bootloaderHash: B256::ZERO,
            defaultAccountHash: B256::ZERO,
            evmEmulatorHash: B256::ZERO,
            verifier: Address::ZERO,
            verifierParams: crate::abi::IChainTypeManager::VerifierParams {
                recursionNodeLevelVkHash: B256::ZERO,
                recursionLeafLevelVkHash: B256::ZERO,
                recursionCircuitsSetVksHash: B256::ZERO,
            },
            l1ContractsUpgradeCalldata: Bytes::new(),
            postUpgradeCalldata: Bytes::new(),
            upgradeTimestamp: U256::ZERO,
            newProtocolVersion: U256::ZERO,
        };
        let mut init_calldata = vec![0_u8; 4];
        init_calldata.extend(proposed.abi_encode());

        let err = tx_hash_from_init_calldata(
            &provider,
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            270,
            protocol_version(31),
            &init_calldata,
        )
        .await
        .unwrap_err();

        assert!(err.to_string().contains("txType is zero"));
        assert!(asserter.read_q().is_empty());
    }
}
