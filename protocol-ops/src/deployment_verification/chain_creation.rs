//! Chain creation parameters: what a chain created from this CTM will get.
//!
//! The CTM only stores three hashes (`storedBatchZero`, `initialCutHash`,
//! `initialForceDeploymentHash`), so the parameters themselves are recovered
//! from the `NewChainCreationParams` event and then bound back to those
//! hashes. If the recomputation matches, the decoded event *is* the live
//! configuration and every field below can be checked against it.

use std::collections::{HashMap, HashSet};
use std::str::FromStr;

use alloy::primitives::{keccak256, Address, Bytes, FixedBytes, U256};
use alloy::providers::Provider;
use alloy::rpc::types::Filter;
use alloy::sol_types::{SolEvent, SolValue};
use anyhow::Context;
use blake2::digest::consts::U32;
use blake2::{Blake2s, Digest};

use crate::common::ethereum::AlloyProvider;
use crate::deployment_verification::contracts::{
    DiamondCutData, FixedForceDeploymentsData, IEcosystemEvents, StoredBatchInfo,
};
use crate::upgrade_verification::versions::v31::utils::bytecode_verifier::ContractHashes;

/// `keccak256("")`, the empty priority-operations hash in batch zero.
fn empty_string_keccak() -> FixedBytes<32> {
    keccak256([])
}

pub struct ChainCreationParams {
    pub genesis_upgrade: Address,
    pub genesis_batch_hash: FixedBytes<32>,
    pub genesis_index_repeated_storage_changes: u64,
    pub genesis_batch_commitment: FixedBytes<32>,
    pub diamond_cut: DiamondCutData,
    pub force_deployments_raw: Bytes,
    pub force_deployments: FixedForceDeploymentsData,
    /// Block the params were last set at, for the report.
    pub block_number: u64,
}

/// `ChainTypeManagerBase._processValidatedChainCreationParams` builds batch
/// zero from the genesis parameters and stores its hash.
pub fn stored_batch_zero(
    genesis_batch_hash: FixedBytes<32>,
    genesis_index_repeated_storage_changes: u64,
    genesis_batch_commitment: FixedBytes<32>,
) -> FixedBytes<32> {
    let batch_zero = StoredBatchInfo {
        batchNumber: 0,
        batchHash: genesis_batch_hash,
        indexRepeatedStorageChanges: genesis_index_repeated_storage_changes,
        numberOfLayer1Txs: U256::ZERO,
        priorityOperationsHash: empty_string_keccak(),
        // DEFAULT_L2_LOGS_TREE_ROOT_HASH is bytes32(0) in this release.
        dependencyRootsRollingHash: FixedBytes::ZERO,
        l2LogsTreeRoot: FixedBytes::ZERO,
        timestamp: U256::ZERO,
        commitment: genesis_batch_commitment,
    };
    keccak256(batch_zero.abi_encode())
}

impl ChainCreationParams {
    pub fn recompute_stored_batch_zero(&self) -> FixedBytes<32> {
        stored_batch_zero(
            self.genesis_batch_hash,
            self.genesis_index_repeated_storage_changes,
            self.genesis_batch_commitment,
        )
    }

    pub fn recompute_initial_cut_hash(&self) -> FixedBytes<32> {
        keccak256(self.diamond_cut.abi_encode())
    }

    pub fn recompute_force_deployment_hash(&self) -> FixedBytes<32> {
        keccak256(self.force_deployments_raw.abi_encode())
    }
}

/// Fetches the most recent `NewChainCreationParams` emitted by `ctm`.
pub async fn fetch(
    provider: &AlloyProvider,
    ctm: Address,
    from_block: u64,
    to_block: u64,
) -> anyhow::Result<ChainCreationParams> {
    let filter = Filter::new()
        .address(ctm)
        .event_signature(IEcosystemEvents::NewChainCreationParams::SIGNATURE_HASH)
        .from_block(from_block)
        .to_block(to_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for NewChainCreationParams")?;
    let log = logs.last().ok_or_else(|| {
        anyhow::anyhow!(
            "no NewChainCreationParams event from the CTM at or after block {from_block}. \
             Pass --from-block with a block at or before the CTM deployment."
        )
    })?;

    let decoded = IEcosystemEvents::NewChainCreationParams::decode_log_data(log.data())
        .context("decoding NewChainCreationParams")?;
    let force_deployments = FixedForceDeploymentsData::abi_decode(&decoded.forceDeploymentsData)
        .context("decoding FixedForceDeploymentsData")?;

    Ok(ChainCreationParams {
        genesis_upgrade: decoded.genesisUpgrade,
        genesis_batch_hash: decoded.genesisBatchHash,
        genesis_index_repeated_storage_changes: decoded.genesisIndexRepeatedStorageChanges,
        genesis_batch_commitment: decoded.genesisBatchCommitment,
        diamond_cut: decoded.newInitialCut,
        force_deployments_raw: decoded.forceDeploymentsData,
        force_deployments,
        block_number: log.block_number.unwrap_or_default(),
    })
}

/// One `ZKSyncOSBytecodeInfo` half: `abi.encode(blake2s, uint32 length, keccak)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BytecodeInfo {
    pub blake: FixedBytes<32>,
    pub length: u32,
    pub keccak: FixedBytes<32>,
}

impl BytecodeInfo {
    fn decode(raw: &[u8]) -> anyhow::Result<Self> {
        let (blake, length, keccak) =
            <(FixedBytes<32>, u32, FixedBytes<32>)>::abi_decode_params(raw)
                .context("decoding ZKSyncOSBytecodeInfo")?;
        Ok(Self {
            blake,
            length,
            keccak,
        })
    }

    pub fn of(code: &[u8]) -> Self {
        let mut hasher = Blake2s::<U32>::new();
        hasher.update(code);
        Self {
            blake: FixedBytes::from_slice(&hasher.finalize()),
            length: code.len() as u32,
            keccak: keccak256(code),
        }
    }
}

/// A force-deployed L2 contract's `(implementation, SystemContractProxy)` pair.
pub struct ForceDeploymentEntry {
    pub field: &'static str,
    pub contract: &'static str,
    pub implementation: BytecodeInfo,
    pub proxy: BytecodeInfo,
}

/// How a force-deployment entry compares to `AllContractsHashes.json`.
///
/// There is no metadata-tolerant verdict here on purpose. These hashes are
/// taken over L2 bytecode that never lands on L1, so the only reference is the
/// repo's committed hash record — and against a fixed record an exact match is
/// achievable, which makes anything else an error rather than a judgement call.
pub enum BytecodeInfoVerdict {
    /// blake2s, length and keccak all match the committed record.
    Exact,
    /// At least one of the three differs.
    Mismatch { expected: BytecodeInfo },
    /// The contract has no entry in `AllContractsHashes.json`.
    MissingRecord,
}

/// The committed `(blake2s, length, keccak)` record for every contract, read
/// from `AllContractsHashes.json`.
///
/// This is the reference for L2 bytecode rather than a local `out/` build: the
/// file is committed and CI-checked, so it does not move with whoever happens
/// to run `forge build`.
pub struct L2BytecodeRecord(HashMap<String, BytecodeInfo>);

impl L2BytecodeRecord {
    pub fn load() -> anyhow::Result<Self> {
        let hashes = ContractHashes::init_from_local()?;
        let mut out = HashMap::new();
        for contract in hashes.hashes {
            // Era-only entries carry no EVM deployed-bytecode triple.
            let (Some(blake), Some(length), Some(keccak)) = (
                contract.evm_deployed_bytecode_blake_hash.as_deref(),
                contract.evm_deployed_bytecode_length,
                contract.evm_deployed_bytecode_hash.as_deref(),
            ) else {
                continue;
            };
            out.insert(
                contract.contract_name.clone(),
                BytecodeInfo {
                    blake: parse_b256(blake)
                        .with_context(|| format!("{} blake hash", contract.contract_name))?,
                    length,
                    keccak: parse_b256(keccak)
                        .with_context(|| format!("{} keccak hash", contract.contract_name))?,
                },
            );
        }
        anyhow::ensure!(
            !out.is_empty(),
            "AllContractsHashes.json carries no EVM deployed-bytecode hashes; run \
             `yarn calculate-hashes:fix` from the repository root"
        );
        Ok(Self(out))
    }

    pub fn get(&self, contract: &str) -> Option<&BytecodeInfo> {
        self.0.get(contract)
    }
}

fn parse_b256(value: &str) -> anyhow::Result<FixedBytes<32>> {
    FixedBytes::<32>::from_str(value.trim_start_matches("0x"))
        .with_context(|| format!("not a 32-byte hex value: {value}"))
}

pub fn force_deployment_entries(
    data: &FixedForceDeploymentsData,
) -> anyhow::Result<Vec<ForceDeploymentEntry>> {
    // (event field, the contract's name in `AllContractsHashes.json`, encoded blob)
    let raw: [(&'static str, &'static str, &Bytes); 10] = [
        (
            "bridgehub",
            "l1-contracts/L2Bridgehub",
            &data.bridgehubBytecodeInfo,
        ),
        (
            "l2AssetRouter",
            "l1-contracts/L2AssetRouter",
            &data.l2AssetRouterBytecodeInfo,
        ),
        (
            "l2Ntv",
            "l1-contracts/L2NativeTokenVaultZKOS",
            &data.l2NtvBytecodeInfo,
        ),
        (
            "messageRoot",
            "l1-contracts/L2MessageRoot",
            &data.messageRootBytecodeInfo,
        ),
        (
            "chainAssetHandler",
            "l1-contracts/L2ChainAssetHandler",
            &data.chainAssetHandlerBytecodeInfo,
        ),
        (
            "interopCenter",
            "l1-contracts/InteropCenter",
            &data.interopCenterBytecodeInfo,
        ),
        (
            "interopHandler",
            "l1-contracts/L2InteropHandler",
            &data.interopHandlerBytecodeInfo,
        ),
        (
            "assetTracker",
            "l1-contracts/L2AssetTracker",
            &data.assetTrackerBytecodeInfo,
        ),
        (
            "beaconDeployer",
            "l1-contracts/UpgradeableBeaconDeployer",
            &data.beaconDeployerInfo,
        ),
        (
            "baseTokenHolder",
            "l1-contracts/BaseTokenHolder",
            &data.baseTokenHolderBytecodeInfo,
        ),
    ];

    raw.into_iter()
        .map(|(field, contract, blob)| {
            // `abi.encode(bytes, bytes)` — Solidity's params encoding, not a
            // single wrapped tuple.
            let (implementation, proxy) = <(Bytes, Bytes)>::abi_decode_params(blob)
                .with_context(|| format!("decoding {field} bytecode info pair"))?;
            Ok(ForceDeploymentEntry {
                field,
                contract,
                implementation: BytecodeInfo::decode(&implementation)?,
                proxy: BytecodeInfo::decode(&proxy)?,
            })
        })
        .collect()
}

/// Compares one force-deployment bytecode info against the committed record.
pub fn verify_bytecode_info(
    record: &L2BytecodeRecord,
    contract: &str,
    on_chain: &BytecodeInfo,
) -> BytecodeInfoVerdict {
    match record.get(contract) {
        Some(expected) if expected == on_chain => BytecodeInfoVerdict::Exact,
        Some(expected) => BytecodeInfoVerdict::Mismatch {
            expected: expected.clone(),
        },
        None => BytecodeInfoVerdict::MissingRecord,
    }
}

/// `SystemContractProxy` is force-deployed at every fixed L2 core address,
/// so a wrong proxy half is as damaging as a wrong implementation.
pub const SYSTEM_CONTRACT_PROXY_CONTRACT: &str = "l1-contracts/SystemContractProxy";

/// `l2TokenProxyBytecodeHash` is `keccak256` of the deployed `BeaconProxy`
/// bytecode and is persisted into the L2 native token vault at genesis.
pub const BEACON_PROXY_CONTRACT: &str = "l1-contracts/BeaconProxy";

/// Selectors listed in the cut for one facet, as a set.
pub fn cut_selectors(selectors: &[alloy::primitives::FixedBytes<4>]) -> HashSet<[u8; 4]> {
    selectors.iter().map(|selector| selector.0).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blake2s_matches_the_scripts_helper() {
        // `l1-contracts/scripts/blake2s256.js` on the empty input.
        let info = BytecodeInfo::of(&[]);
        assert_eq!(
            alloy::hex::encode(info.blake),
            "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"
        );
        assert_eq!(info.length, 0);
    }

    /// Pinned against the live v0.33.0 Sepolia ecosystem: genesis root
    /// 0x959644fb…, ZKsync OS commitment 1, no repeated storage changes.
    fn record_of(contract: &str, info: BytecodeInfo) -> L2BytecodeRecord {
        L2BytecodeRecord(HashMap::from([(contract.to_string(), info)]))
    }

    /// The reference is a fixed, committed record, so an exact match is
    /// achievable and anything short of it is an error — in particular a hash
    /// pair that merely carries the right length.
    #[test]
    fn only_an_exact_triple_passes() {
        let expected = BytecodeInfo::of(&[0x60u8; 128]);
        let record = record_of("l1-contracts/L2Bridgehub", expected.clone());

        assert!(matches!(
            verify_bytecode_info(&record, "l1-contracts/L2Bridgehub", &expected),
            BytecodeInfoVerdict::Exact
        ));

        for wrong in [
            BytecodeInfo {
                blake: FixedBytes::repeat_byte(0xAB),
                ..expected.clone()
            },
            BytecodeInfo {
                keccak: FixedBytes::repeat_byte(0xCD),
                ..expected.clone()
            },
            BytecodeInfo {
                length: expected.length + 1,
                ..expected.clone()
            },
        ] {
            assert!(matches!(
                verify_bytecode_info(&record, "l1-contracts/L2Bridgehub", &wrong),
                BytecodeInfoVerdict::Mismatch { .. }
            ));
        }
    }

    #[test]
    fn a_contract_absent_from_the_record_is_an_error() {
        let record = record_of("l1-contracts/L2Bridgehub", BytecodeInfo::of(&[0x60u8; 4]));
        assert!(matches!(
            verify_bytecode_info(
                &record,
                "l1-contracts/InteropCenter",
                &BytecodeInfo::of(&[])
            ),
            BytecodeInfoVerdict::MissingRecord
        ));
    }

    /// The committed record must actually carry the ZKsync OS force-deployment
    /// contracts; a rename that silently drops one would turn every entry into
    /// `MissingRecord`.
    #[test]
    fn the_committed_record_covers_every_force_deployed_contract() {
        let Ok(record) = L2BytecodeRecord::load() else {
            // AllContractsHashes.json is not present in every checkout layout.
            return;
        };
        for contract in [
            "l1-contracts/L2Bridgehub",
            "l1-contracts/L2AssetRouter",
            "l1-contracts/L2NativeTokenVaultZKOS",
            "l1-contracts/L2MessageRoot",
            "l1-contracts/L2ChainAssetHandler",
            "l1-contracts/InteropCenter",
            "l1-contracts/L2InteropHandler",
            "l1-contracts/L2AssetTracker",
            "l1-contracts/UpgradeableBeaconDeployer",
            "l1-contracts/BaseTokenHolder",
            SYSTEM_CONTRACT_PROXY_CONTRACT,
            BEACON_PROXY_CONTRACT,
        ] {
            assert!(
                record.get(contract).is_some(),
                "{contract} missing from AllContractsHashes.json"
            );
        }
    }

    #[test]
    fn stored_batch_zero_matches_the_deployed_ctm() {
        let genesis_root = FixedBytes::new(alloy::hex!(
            "959644fbfa5658ba3c4c0a7486d9c5892ab0c25982ae9fcad335d4d34f5d46ff"
        ));
        assert_eq!(
            stored_batch_zero(genesis_root, 0, FixedBytes::left_padding_from(&[1])),
            FixedBytes::new(alloy::hex!(
                "63cdd29fd84683302a9472e47fe77756b8f8042bf2b5f13ed1988ff75f799789"
            ))
        );
    }
}
