//! Chain creation parameters: what a chain created from this CTM will get.
//!
//! The CTM only stores three hashes (`storedBatchZero`, `initialCutHash`,
//! `initialForceDeploymentHash`), so the parameters themselves are recovered
//! from the `NewChainCreationParams` event and then bound back to those
//! hashes. If the recomputation matches, the decoded event *is* the live
//! configuration and every field below can be checked against it.

use std::collections::{HashMap, HashSet};

use alloy::primitives::{keccak256, Address, Bytes, FixedBytes, U256};
use alloy::providers::Provider;
use alloy::rpc::types::Filter;
use alloy::sol_types::{SolEvent, SolValue};
use anyhow::Context;
use blake2::digest::consts::U32;
use blake2::{Blake2s, Digest};

use crate::common::ethereum::AlloyProvider;
use crate::deployment_verification::artifact_index::{ArtifactIndex, CodeMatch};
use crate::deployment_verification::contracts::{
    DiamondCutData, FixedForceDeploymentsData, IEcosystemEvents, StoredBatchInfo,
};

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
    pub artifact: &'static str,
    pub implementation: BytecodeInfo,
    pub proxy: BytecodeInfo,
}

/// How a force-deployment entry compares to the local build.
pub enum BytecodeInfoVerdict {
    /// blake2s, length and keccak all match the local artifact.
    Exact,
    /// The bytecode behind the on-chain hash was recovered from a
    /// `BytecodesSupplier` publication and differs from the local artifact
    /// only in its CBOR metadata. Unlike a bare hash comparison this is
    /// proven, because the preimage was available.
    MetadataOnlyProven { digests: usize },
    /// The hashes differ and the preimage is not published on L1, so nothing
    /// can be concluded: equal lengths do not imply equal code.
    Unverifiable,
    /// Length differs, or the recovered preimage is a different contract.
    Mismatch { local: BytecodeInfo },
    /// No artifact of that name in the local build.
    MissingArtifact,
}

pub fn force_deployment_entries(
    data: &FixedForceDeploymentsData,
) -> anyhow::Result<Vec<ForceDeploymentEntry>> {
    // (event field, L2 contract as `CoreOnGatewayHelper._resolveContractName`
    // resolves it for ZKsync OS, encoded blob)
    let raw: [(&'static str, &'static str, &Bytes); 10] = [
        ("bridgehub", "L2Bridgehub", &data.bridgehubBytecodeInfo),
        (
            "l2AssetRouter",
            "L2AssetRouter",
            &data.l2AssetRouterBytecodeInfo,
        ),
        ("l2Ntv", "L2NativeTokenVaultZKOS", &data.l2NtvBytecodeInfo),
        (
            "messageRoot",
            "L2MessageRoot",
            &data.messageRootBytecodeInfo,
        ),
        (
            "chainAssetHandler",
            "L2ChainAssetHandler",
            &data.chainAssetHandlerBytecodeInfo,
        ),
        (
            "interopCenter",
            "InteropCenter",
            &data.interopCenterBytecodeInfo,
        ),
        (
            "interopHandler",
            "L2InteropHandler",
            &data.interopHandlerBytecodeInfo,
        ),
        (
            "assetTracker",
            "L2AssetTracker",
            &data.assetTrackerBytecodeInfo,
        ),
        (
            "beaconDeployer",
            "UpgradeableBeaconDeployer",
            &data.beaconDeployerInfo,
        ),
        (
            "baseTokenHolder",
            "BaseTokenHolder",
            &data.baseTokenHolderBytecodeInfo,
        ),
    ];

    raw.into_iter()
        .map(|(field, artifact, blob)| {
            // `abi.encode(bytes, bytes)` — Solidity's params encoding, not a
            // single wrapped tuple.
            let (implementation, proxy) = <(Bytes, Bytes)>::abi_decode_params(blob)
                .with_context(|| format!("decoding {field} bytecode info pair"))?;
            Ok(ForceDeploymentEntry {
                field,
                artifact,
                implementation: BytecodeInfo::decode(&implementation)?,
                proxy: BytecodeInfo::decode(&proxy)?,
            })
        })
        .collect()
}

/// Compares one force-deployment bytecode info against the local build.
///
/// `published` maps a keccak to the bytecode behind it, recovered from
/// `BytecodesSupplier` publications. Without the preimage a differing hash
/// pair proves nothing — in particular, equal lengths do not imply equal
/// executable code — so the verdict is `Unverifiable` rather than a guess.
pub fn verify_bytecode_info(
    index: &ArtifactIndex,
    artifact_name: &str,
    on_chain: &BytecodeInfo,
    published: &HashMap<FixedBytes<32>, Bytes>,
) -> BytecodeInfoVerdict {
    let Some(artifact) = index.get(artifact_name) else {
        return BytecodeInfoVerdict::MissingArtifact;
    };
    let local = BytecodeInfo::of(&artifact.deployed_code);
    if local == *on_chain {
        return BytecodeInfoVerdict::Exact;
    }
    match published.get(&on_chain.keccak) {
        Some(preimage) => match artifact.compare(preimage) {
            // An exact match here would have matched the hashes above, so
            // reaching it means the artifact hashes differently than its own
            // bytes — impossible; treat anything but metadata-only as a
            // divergence.
            Some(CodeMatch::MetadataOnly { digests }) => {
                BytecodeInfoVerdict::MetadataOnlyProven { digests }
            }
            _ => BytecodeInfoVerdict::Mismatch { local },
        },
        None if local.length != on_chain.length => BytecodeInfoVerdict::Mismatch { local },
        None => BytecodeInfoVerdict::Unverifiable,
    }
}

/// Recovers the bytecode behind published hashes from `BytecodesSupplier`.
///
/// `EVMBytecodePublished` carries the full preimage, which is the only way to
/// tell "same code, different build metadata" from "different code, same
/// length" for the hashes the chain creation params commit to.
pub async fn published_bytecodes(
    provider: &AlloyProvider,
    supplier: Address,
    from_block: u64,
    to_block: u64,
) -> anyhow::Result<HashMap<FixedBytes<32>, Bytes>> {
    let filter = Filter::new()
        .address(supplier)
        .event_signature(IEcosystemEvents::EVMBytecodePublished::SIGNATURE_HASH)
        .from_block(from_block)
        .to_block(to_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .context("eth_getLogs for EVMBytecodePublished")?;
    logs.iter()
        .map(|log| {
            let event = IEcosystemEvents::EVMBytecodePublished::decode_log_data(log.data())
                .context("decoding EVMBytecodePublished")?;
            Ok((event.bytecodeHash, event.bytecode))
        })
        .collect()
}

/// `SystemContractProxy` is force-deployed at every fixed L2 core address,
/// so a wrong proxy half is as damaging as a wrong implementation.
pub const SYSTEM_CONTRACT_PROXY_ARTIFACT: &str = "SystemContractProxy";

/// `l2TokenProxyBytecodeHash` is `keccak256` of the deployed `BeaconProxy`
/// bytecode and is persisted into the L2 native token vault at genesis.
pub const BEACON_PROXY_ARTIFACT: &str = "BeaconProxy";

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
    fn index_with(name: &str, code: Vec<u8>) -> ArtifactIndex {
        ArtifactIndex::from_artifacts(vec![
            crate::deployment_verification::artifact_index::Artifact::for_test(name, code),
        ])
    }

    /// The whole point of the verdict: a hash the local build does not produce
    /// is not excused by having the right length. Only a published preimage can
    /// establish a metadata-only difference.
    #[test]
    fn same_length_but_different_hashes_is_unverifiable_not_metadata() {
        let local = vec![0x60u8; 128];
        let index = index_with("L2Bridgehub", local.clone());
        let forged = BytecodeInfo {
            blake: FixedBytes::repeat_byte(0xAB),
            length: local.len() as u32,
            keccak: FixedBytes::repeat_byte(0xCD),
        };
        assert!(matches!(
            verify_bytecode_info(&index, "L2Bridgehub", &forged, &HashMap::new()),
            BytecodeInfoVerdict::Unverifiable
        ));

        let honest = BytecodeInfo::of(&local);
        assert!(matches!(
            verify_bytecode_info(&index, "L2Bridgehub", &honest, &HashMap::new()),
            BytecodeInfoVerdict::Exact
        ));
    }

    #[test]
    fn a_different_length_is_always_a_mismatch() {
        let index = index_with("L2Bridgehub", vec![0x60u8; 128]);
        let other = BytecodeInfo::of(&[0x60u8; 64]);
        assert!(matches!(
            verify_bytecode_info(&index, "L2Bridgehub", &other, &HashMap::new()),
            BytecodeInfoVerdict::Mismatch { .. }
        ));
    }

    /// With the preimage published, a metadata-only difference becomes provable
    /// and an unrelated contract behind the same hash stays a mismatch.
    #[test]
    fn a_published_preimage_settles_the_verdict() {
        const TAG: [u8; 8] = [0xa2, 0x64, 0x69, 0x70, 0x66, 0x73, 0x58, 0x22];
        let mut local = vec![0x60u8; 40];
        local.extend_from_slice(&TAG);
        local.extend_from_slice(&[0xAA; 34]);
        let index = index_with("L2Bridgehub", local.clone());

        let mut rebuilt = local.clone();
        rebuilt[40 + TAG.len()..].fill(0xBB);
        let info = BytecodeInfo::of(&rebuilt);
        let published = HashMap::from([(info.keccak, Bytes::from(rebuilt))]);
        assert!(matches!(
            verify_bytecode_info(&index, "L2Bridgehub", &info, &published),
            BytecodeInfoVerdict::MetadataOnlyProven { digests: 1 }
        ));

        let unrelated = vec![0x5bu8; local.len()];
        let unrelated_info = BytecodeInfo::of(&unrelated);
        let published = HashMap::from([(unrelated_info.keccak, Bytes::from(unrelated))]);
        assert!(matches!(
            verify_bytecode_info(&index, "L2Bridgehub", &unrelated_info, &published),
            BytecodeInfoVerdict::Mismatch { .. }
        ));
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
