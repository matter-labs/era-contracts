//! Locate the pending protocol upgrade transaction on the settlement layer and
//! compute its canonical hash.

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::{DynProvider, Provider};
use alloy::rpc::types::{Filter, Log};
use alloy::sol_types::{SolCall, SolEvent, SolValue};
use anyhow::{anyhow, Context};
use tracing::{debug, info};

use crate::abi::{
    BaseZkSyncUpgrade::UpgradeComplete,
    IBootstrapUpgrade,
    IBridgehub::IBridgehubInstance,
    ICTMTransition::ICTMTransitionInstance,
    IChainTypeManager::{IChainTypeManagerInstance, NewUpgradeCutData},
    IDefaultUpgrade,
    ILegacySettlementLayerUpgrade::ILegacySettlementLayerUpgradeInstance,
    IRegistryBootstrapMigration,
    ISettlementLayerUpgrade::{upgradeVerifierOnlyCall, ISettlementLayerUpgradeInstance},
    L2CanonicalTransaction,
};

/// How many settlement-layer blocks to scan per `eth_getLogs` request. Keeps us under
/// typical provider limits while still terminating in a reasonable number of round trips.
const MAX_BLOCKS_PER_QUERY: u64 = 50_000;

/// Bit offset of the minor component in the packed protocol version.
const PACKED_SEMVER_MINOR_OFFSET: usize = 32;

/// First protocol minor whose upgrade transaction data is rewritten per chain.
const FIRST_PER_CHAIN_REWRITE_PROTOCOL_MINOR: u64 = 31;

/// Diagnostic for an upgrade that commits the all-zero L2 transaction (patch and L1-only
/// upgrades): no receipt will ever exist for it, so waiting for one would never end.
const NO_L2_UPGRADE_TX: &str =
    "upgrade has no L2 protocol transaction (txType is zero); receipt-based readiness does not apply";

/// Resolve the chain's ChainTypeManager by calling `Bridgehub.chainTypeManager(chainId)`
/// on the layer the bridgehub lives on.
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

/// Compute the canonical hash of the L2 upgrade transaction `chain_id` executes to reach
/// `protocol_version`.
///
/// The newest `NewUpgradeCutData(protocol_version)` event on the CTM proves that a cut for the
/// target was published and tells its shape by the init selector:
/// - a registry edge (`upgradeFromTransition`) is resolved for this chain by
///   [`registry_edge_tx_hash`], not from that cut: `replaceUpgradeTransition` publishes a second
///   cut under the same target (e.g. a skip-ahead departing an older version), so the newest one
///   need not be the edge this chain crosses;
/// - a bootstrap or legacy cut is unique per target and is read by
///   [`tx_hash_from_init_calldata`].
///
/// `lookback_blocks` caps how far back the settlement layer is scanned.
pub async fn find_upgrade_tx_hash(
    provider: &DynProvider,
    ctm_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
    protocol_version: U256,
    lookback_blocks: u64,
) -> anyhow::Result<B256> {
    let filter = Filter::new()
        .address(ctm_address)
        .event_signature(NewUpgradeCutData::SIGNATURE_HASH)
        .topic1(B256::from(protocol_version.to_be_bytes::<32>()));
    let log = newest_log(
        provider,
        &filter,
        lookback_blocks,
        &format!(
            "NewUpgradeCutData event for protocol version {protocol_version} on CTM {ctm_address}"
        ),
    )
    .await?;
    let diamond_cut = log
        .log_decode::<NewUpgradeCutData>()
        .context("NewUpgradeCutData event decode failed — ABI mismatch with the deployed CTM")?
        .inner
        .data
        .diamondCutData;

    if diamond_cut
        .initCalldata
        .starts_with(&IDefaultUpgrade::upgradeFromTransitionCall::SELECTOR)
    {
        return registry_edge_tx_hash(
            provider,
            ctm_address,
            bridgehub_address,
            chain_id,
            protocol_version,
            lookback_blocks,
        )
        .await;
    }
    tx_hash_from_init_calldata(
        provider,
        diamond_cut.initAddress,
        bridgehub_address,
        chain_id,
        protocol_version,
        &diamond_cut.initCalldata,
    )
    .await
}

/// The newest log matching `filter` (address and topics, no block range) within the last
/// `lookback_blocks` blocks. Scans newest-first in `MAX_BLOCKS_PER_QUERY` chunks so recent
/// events are found in few round trips. `description` names the awaited event in errors.
async fn newest_log(
    provider: &DynProvider,
    filter: &Filter,
    lookback_blocks: u64,
    description: &str,
) -> anyhow::Result<Log> {
    let latest = provider.get_block_number().await?;
    let start = latest.saturating_sub(lookback_blocks).max(1);

    let mut to = latest;
    while to >= start {
        let from = to.saturating_sub(MAX_BLOCKS_PER_QUERY - 1).max(start);
        let logs = provider
            .get_logs(&filter.clone().from_block(from).to_block(to))
            .await
            .with_context(|| format!("eth_getLogs {from}..{to} for {description}"))?;

        if let Some(log) = logs.into_iter().last() {
            return Ok(log);
        }

        if from == start {
            break;
        }
        to = from - 1;
    }

    Err(anyhow!(
        "No {description} within the last {lookback_blocks} blocks (scanned {start}..{latest})",
    ))
}

/// Compute the canonical hash of the L2 upgrade transaction `chain_id` executes on its own
/// registry edge to `target`.
///
/// A chain below `target` crosses the transition its CTM commits for the chain's current version
/// (`upgradeTransition`), which must land on `target`; the transaction is the one that transition
/// composes for the chain. A chain at or past `target` already crossed, and its diamond recorded
/// the exact hash in `UpgradeComplete`.
async fn registry_edge_tx_hash(
    provider: &DynProvider,
    ctm_address: Address,
    bridgehub_address: Address,
    chain_id: u64,
    target: U256,
    lookback_blocks: u64,
) -> anyhow::Result<B256> {
    let ctm = IChainTypeManagerInstance::new(ctm_address, provider.clone());
    let chain_version = ctm
        .getProtocolVersion(U256::from(chain_id))
        .call()
        .await
        .context("ChainTypeManager.getProtocolVersion call failed")?;

    if chain_version >= target {
        return recorded_upgrade_tx_hash(
            provider,
            bridgehub_address,
            chain_id,
            chain_version,
            target,
            lookback_blocks,
        )
        .await;
    }

    let transition_address = ctm
        .upgradeTransition(chain_version)
        .call()
        .await
        .context("ChainTypeManager.upgradeTransition call failed")?;
    if transition_address == Address::ZERO {
        anyhow::bail!(
            "CTM {ctm_address} has no upgrade transition committed for protocol version {chain_version}, which chain {chain_id} is at; there is no registry edge for it to cross toward {target}"
        );
    }
    let transition = ICTMTransitionInstance::new(transition_address, provider.clone());
    let next_version = transition
        .newProtocolVersion()
        .call()
        .await
        .context("CTMTransition.newProtocolVersion call failed")?;
    if next_version != target {
        anyhow::bail!(
            "chain {chain_id} at protocol version {chain_version} upgrades to {next_version} next (transition {transition_address}), not to {target}; readiness for {target} does not apply — run the checker for {next_version}"
        );
    }

    info!(%chain_version, transition = %transition_address, "registry edge: reading the L2 tx the chain's own transition composes");
    let tx = transition
        .l2UpgradeTx(bridgehub_address, U256::from(chain_id))
        .call()
        .await
        .context("CTMTransition.l2UpgradeTx call failed")?;
    l2_upgrade_tx_hash(&tx)
}

/// The `l2UpgradeTxHash` the diamond of `chain_id` recorded in `UpgradeComplete` when it
/// crossed to `target`.
async fn recorded_upgrade_tx_hash(
    provider: &DynProvider,
    bridgehub_address: Address,
    chain_id: u64,
    chain_version: U256,
    target: U256,
    lookback_blocks: u64,
) -> anyhow::Result<B256> {
    let diamond = IBridgehubInstance::new(bridgehub_address, provider.clone())
        .getZKChain(U256::from(chain_id))
        .call()
        .await
        .context("Bridgehub.getZKChain call failed")?;
    info!(%chain_version, %diamond, "registry edge already crossed: reading the hash the chain's diamond recorded");

    let filter = Filter::new()
        .address(diamond)
        .event_signature(UpgradeComplete::SIGNATURE_HASH)
        .topic1(B256::from(target.to_be_bytes::<32>()));
    let log = newest_log(
        provider,
        &filter,
        lookback_blocks,
        &format!(
            "UpgradeComplete event for protocol version {target} on diamond {diamond} of chain {chain_id} (now at protocol version {chain_version})"
        ),
    )
    .await?;
    let tx_hash = log
        .log_decode::<UpgradeComplete>()
        .context("UpgradeComplete event decode failed — ABI mismatch with the executed upgrade")?
        .inner
        .data
        .l2UpgradeTxHash;
    if tx_hash == B256::ZERO {
        anyhow::bail!(NO_L2_UPGRADE_TX);
    }
    Ok(tx_hash)
}

/// Resolve the L2 protocol upgrade transaction a bootstrap or legacy DiamondCutData init
/// commits on `chain_id` and compute `keccak256(L2CanonicalTransaction.abi_encode())`.
///
/// The init calldata takes one of two shapes, told apart by its selector:
/// - `upgradeFromBootstrap(migration)` — the v35 bootstrap edge: the migration object serves the
///   per-chain transaction via `l2UpgradeTx(chainId)`;
/// - anything else is the legacy `upgrade(ProposedUpgrade)` (pre-v35 cut-taking commits), with
///   the transaction embedded in the struct after the selector and its `.data` mutated per
///   chain by the upgrade contract at execution — replayed here.
///
/// Registry edges (`upgradeFromTransition`) are resolved per chain by [`find_upgrade_tx_hash`]
/// and never reach here.
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
    if init_calldata.starts_with(&upgradeVerifierOnlyCall::SELECTOR) {
        anyhow::bail!(
            "verifier-only upgrade has no L2 protocol transaction; receipt-based readiness does not apply"
        );
    }

    let tx = if init_calldata.starts_with(&IBootstrapUpgrade::upgradeFromBootstrapCall::SELECTOR) {
        let call = IBootstrapUpgrade::upgradeFromBootstrapCall::abi_decode(init_calldata)
            .context("upgradeFromBootstrap(address) decode from initCalldata")?;
        info!(migration = %call._migration, "bootstrap cut: reading the chain's composed L2 tx from the migration");
        IRegistryBootstrapMigration::IRegistryBootstrapMigrationInstance::new(
            call._migration,
            provider.clone(),
        )
        .l2UpgradeTx(U256::from(chain_id))
        .call()
        .await
        .context("RegistryBootstrapMigration.l2UpgradeTx call failed")?
    } else {
        // Legacy cut-taking commit: skip the 4-byte selector and decode the ProposedUpgrade struct.
        let proposed = <crate::abi::IChainTypeManager::ProposedUpgrade as SolValue>::abi_decode(
            &init_calldata[4..],
        )
        .context("ProposedUpgrade decode from initCalldata")?;
        let mut tx = proposed.l2ProtocolUpgradeTx;
        // Checked before the rewrite, which would otherwise query the upgrade contract for a
        // transaction that does not exist.
        if tx.txType == U256::ZERO {
            anyhow::bail!(NO_L2_UPGRADE_TX);
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
        tx
    };

    l2_upgrade_tx_hash(&tx)
}

/// For v31+ upgrade contracts, return the per-chain transaction data produced by the
/// current rewrite ABI, falling back to the legacy ABI used by already-published upgrades.
/// Pre-v31 upgrades did not rewrite the transaction data. A failure of both v31+ ABIs is
/// fatal: silently hashing the placeholder data would make the checker wait for a transaction
/// that can never exist.
/// Registry-driven cuts (v35+) serve the final per-chain transaction directly and
/// never take this path.
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

/// [`canonical_tx_hash`] of the transaction an upgrade commits, refusing the all-zero one
/// (`txType == 0`).
fn l2_upgrade_tx_hash(tx: &L2CanonicalTransaction) -> anyhow::Result<B256> {
    if tx.txType == U256::ZERO {
        anyhow::bail!(NO_L2_UPGRADE_TX);
    }
    Ok(canonical_tx_hash(tx))
}

#[cfg(test)]
mod tests {
    use super::*;

    use alloy::primitives::{LogData, U64};
    use alloy::providers::ProviderBuilder;
    use alloy::transports::mock::Asserter;

    use crate::abi::{
        IBridgehub::getZKChainCall,
        ICTMTransition::{l2UpgradeTxCall as TransitionL2UpgradeTxCall, newProtocolVersionCall},
        IChainTypeManager::{getProtocolVersionCall, upgradeTransitionCall, DiamondCutData},
        ILegacySettlementLayerUpgrade::getL2UpgradeTxDataCall as LegacyGetL2UpgradeTxDataCall,
        IRegistryBootstrapMigration::l2UpgradeTxCall as BootstrapL2UpgradeTxCall,
        ISettlementLayerUpgrade::getL2UpgradeTxDataCall as CurrentGetL2UpgradeTxDataCall,
    };

    const CHAIN_ID: u64 = 270;
    const BRIDGEHUB: Address = Address::repeat_byte(0x22);
    const CTM: Address = Address::repeat_byte(0x33);
    /// The transition the CTM commits for the chain's current version.
    const TRANSITION: Address = Address::repeat_byte(0x44);
    /// A skip-ahead transition published under the same target by `replaceUpgradeTransition`.
    const BYPASS_TRANSITION: Address = Address::repeat_byte(0x45);
    const ENGINE: Address = Address::repeat_byte(0x46);
    const DIAMOND: Address = Address::repeat_byte(0x55);
    const LOOKBACK_BLOCKS: u64 = 2_500_000;
    /// Below `MAX_BLOCKS_PER_QUERY`, so every log scan is a single `eth_getLogs` chunk.
    const LATEST_BLOCK: u64 = 1_000;
    const L2_UPGRADE_TX_TYPE: u64 = 254;

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

    /// A provider answering JSON-RPC requests, in call order, from the returned asserter: the
    /// tests isolate the checker's resolution logic from a live settlement layer.
    fn mocked_provider() -> (Asserter, DynProvider) {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        (asserter, provider)
    }

    /// Queues the ABI-encoded return value of one `C` view call.
    fn push_return<C: SolCall>(asserter: &Asserter, value: &C::Return) {
        asserter.push_success(&Bytes::from(C::abi_encode_returns(value)));
    }

    /// Queues the `eth_blockNumber` and the single `eth_getLogs` response of one log scan.
    fn push_log_scan(asserter: &Asserter, logs: Vec<Log>) {
        asserter.push_success(&U64::from(LATEST_BLOCK));
        asserter.push_success(&logs);
    }

    fn rpc_log(address: Address, data: LogData) -> Log {
        Log {
            inner: alloy::primitives::Log { address, data },
            ..Default::default()
        }
    }

    /// The `NewUpgradeCutData` the CTM publishes when it commits `transition` toward `target`.
    fn transition_cut_log(target: U256, transition: Address) -> Log {
        let event = NewUpgradeCutData {
            protocolVersion: target,
            diamondCutData: DiamondCutData {
                facetCuts: Vec::new(),
                initAddress: ENGINE,
                initCalldata: IDefaultUpgrade::upgradeFromTransitionCall {
                    _transition: transition,
                }
                .abi_encode()
                .into(),
            },
        };
        rpc_log(CTM, event.encode_log_data())
    }

    /// The `UpgradeComplete` the chain's diamond emits when it crosses to `target`.
    fn upgrade_complete_log(target: U256, tx_hash: B256, tx: L2CanonicalTransaction) -> Log {
        let event = UpgradeComplete {
            newProtocolVersion: target,
            l2UpgradeTxHash: tx_hash,
            l2ProtocolUpgradeTx: tx,
        };
        rpc_log(DIAMOND, event.encode_log_data())
    }

    /// The all-zero transaction committed by an upgrade without an L2 step.
    fn empty_tx() -> L2CanonicalTransaction {
        L2CanonicalTransaction {
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
        }
    }

    fn upgrade_tx() -> L2CanonicalTransaction {
        L2CanonicalTransaction {
            txType: U256::from(L2_UPGRADE_TX_TYPE),
            data: Bytes::from_static(b"upgrade"),
            ..empty_tx()
        }
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
        let version = protocol_version(31);
        let init_calldata = upgradeVerifierOnlyCall {
            _newProtocolVersion: version,
        }
        .abi_encode();

        let err = tx_hash_from_init_calldata(
            &provider,
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            270,
            version,
            &init_calldata,
        )
        .await
        .unwrap_err();

        assert!(err
            .to_string()
            .contains("verifier-only upgrade has no L2 protocol transaction"));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn proposal_without_l2_transaction_fails_with_explicit_diagnostic() {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let proposed = crate::abi::IChainTypeManager::ProposedUpgrade {
            l2ProtocolUpgradeTx: empty_tx(),
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

    #[tokio::test]
    async fn bootstrap_cut_without_l2_transaction_fails_with_explicit_diagnostic() {
        let (asserter, provider) = mocked_provider();
        let init_calldata = IBootstrapUpgrade::upgradeFromBootstrapCall {
            _migration: Address::repeat_byte(0x11),
        }
        .abi_encode();
        push_return::<BootstrapL2UpgradeTxCall>(&asserter, &empty_tx());

        let err = tx_hash_from_init_calldata(
            &provider,
            ENGINE,
            BRIDGEHUB,
            CHAIN_ID,
            protocol_version(35),
            &init_calldata,
        )
        .await
        .unwrap_err();

        assert!(err.to_string().contains("txType is zero"));
        assert!(asserter.read_q().is_empty());
    }

    /// `replaceUpgradeTransition` published a skip-ahead cut under the same target after the
    /// chain's own edge. The newest cut only routes to the per-chain resolution: the hash is the
    /// one the transition committed for the chain's version composes, not the bypass's.
    #[tokio::test]
    async fn newest_registry_cut_is_not_taken_as_the_chains_edge() {
        let (asserter, provider) = mocked_provider();
        let target = protocol_version(33);
        push_log_scan(
            &asserter,
            vec![
                transition_cut_log(target, TRANSITION),
                transition_cut_log(target, BYPASS_TRANSITION),
            ],
        );
        push_return::<getProtocolVersionCall>(&asserter, &protocol_version(32));
        push_return::<upgradeTransitionCall>(&asserter, &TRANSITION);
        push_return::<newProtocolVersionCall>(&asserter, &target);
        push_return::<TransitionL2UpgradeTxCall>(&asserter, &upgrade_tx());

        let actual =
            find_upgrade_tx_hash(&provider, CTM, BRIDGEHUB, CHAIN_ID, target, LOOKBACK_BLOCKS)
                .await
                .unwrap();

        assert_eq!(actual, canonical_tx_hash(&upgrade_tx()));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn registry_edge_before_crossing_hashes_the_chains_transition_tx() {
        let (asserter, provider) = mocked_provider();
        let target = protocol_version(33);
        push_return::<getProtocolVersionCall>(&asserter, &protocol_version(32));
        push_return::<upgradeTransitionCall>(&asserter, &TRANSITION);
        push_return::<newProtocolVersionCall>(&asserter, &target);
        push_return::<TransitionL2UpgradeTxCall>(&asserter, &upgrade_tx());

        let actual =
            registry_edge_tx_hash(&provider, CTM, BRIDGEHUB, CHAIN_ID, target, LOOKBACK_BLOCKS)
                .await
                .unwrap();

        assert_eq!(actual, canonical_tx_hash(&upgrade_tx()));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn registry_edge_without_l2_transaction_fails_with_explicit_diagnostic() {
        let (asserter, provider) = mocked_provider();
        let target = protocol_version(33);
        push_return::<getProtocolVersionCall>(&asserter, &protocol_version(32));
        push_return::<upgradeTransitionCall>(&asserter, &TRANSITION);
        push_return::<newProtocolVersionCall>(&asserter, &target);
        push_return::<TransitionL2UpgradeTxCall>(&asserter, &empty_tx());

        let err =
            registry_edge_tx_hash(&provider, CTM, BRIDGEHUB, CHAIN_ID, target, LOOKBACK_BLOCKS)
                .await
                .unwrap_err();

        assert!(err.to_string().contains("txType is zero"));
        assert!(asserter.read_q().is_empty());
    }

    /// The chain's committed edge lands on another version (an intermediate one, or a skip-ahead
    /// past the target): the chain never executes an upgrade to the target from here.
    #[tokio::test]
    async fn registry_edge_to_another_version_fails_naming_it() {
        let (asserter, provider) = mocked_provider();
        let next_version = protocol_version(33);
        push_return::<getProtocolVersionCall>(&asserter, &protocol_version(32));
        push_return::<upgradeTransitionCall>(&asserter, &TRANSITION);
        push_return::<newProtocolVersionCall>(&asserter, &next_version);

        let err = registry_edge_tx_hash(
            &provider,
            CTM,
            BRIDGEHUB,
            CHAIN_ID,
            protocol_version(34),
            LOOKBACK_BLOCKS,
        )
        .await
        .unwrap_err();

        assert!(err
            .to_string()
            .contains(&format!("run the checker for {next_version}")));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn registry_edge_without_committed_transition_fails() {
        let (asserter, provider) = mocked_provider();
        push_return::<getProtocolVersionCall>(&asserter, &protocol_version(32));
        push_return::<upgradeTransitionCall>(&asserter, &Address::ZERO);

        let err = registry_edge_tx_hash(
            &provider,
            CTM,
            BRIDGEHUB,
            CHAIN_ID,
            protocol_version(33),
            LOOKBACK_BLOCKS,
        )
        .await
        .unwrap_err();

        assert!(err
            .to_string()
            .contains("has no upgrade transition committed"));
        assert!(asserter.read_q().is_empty());
    }

    /// The hash comes from the event's indexed topic as the diamond recorded it, so it is
    /// deliberately not the hash of the logged transaction.
    #[tokio::test]
    async fn registry_edge_after_crossing_returns_hash_recorded_by_diamond() {
        let (asserter, provider) = mocked_provider();
        let target = protocol_version(33);
        let recorded = B256::repeat_byte(0x66);
        push_return::<getProtocolVersionCall>(&asserter, &target);
        push_return::<getZKChainCall>(&asserter, &DIAMOND);
        push_log_scan(
            &asserter,
            vec![upgrade_complete_log(target, recorded, upgrade_tx())],
        );

        let actual =
            registry_edge_tx_hash(&provider, CTM, BRIDGEHUB, CHAIN_ID, target, LOOKBACK_BLOCKS)
                .await
                .unwrap();

        assert_eq!(actual, recorded);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn registry_edge_crossed_without_l2_transaction_fails_with_explicit_diagnostic() {
        let (asserter, provider) = mocked_provider();
        let target = protocol_version(33);
        push_return::<getProtocolVersionCall>(&asserter, &target);
        push_return::<getZKChainCall>(&asserter, &DIAMOND);
        push_log_scan(
            &asserter,
            vec![upgrade_complete_log(target, B256::ZERO, empty_tx())],
        );

        let err =
            registry_edge_tx_hash(&provider, CTM, BRIDGEHUB, CHAIN_ID, target, LOOKBACK_BLOCKS)
                .await
                .unwrap_err();

        assert!(err.to_string().contains("txType is zero"));
        assert!(asserter.read_q().is_empty());
    }

    /// A chain past the target that skipped it (a skip-ahead edge) never recorded crossing it.
    #[tokio::test]
    async fn registry_edge_past_target_without_upgrade_complete_fails() {
        let (asserter, provider) = mocked_provider();
        push_return::<getProtocolVersionCall>(&asserter, &protocol_version(34));
        push_return::<getZKChainCall>(&asserter, &DIAMOND);
        push_log_scan(&asserter, Vec::new());

        let err = registry_edge_tx_hash(
            &provider,
            CTM,
            BRIDGEHUB,
            CHAIN_ID,
            protocol_version(33),
            LOOKBACK_BLOCKS,
        )
        .await
        .unwrap_err();

        assert!(err.to_string().contains("No UpgradeComplete event"));
        assert!(asserter.read_q().is_empty());
    }
}
