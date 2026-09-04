//! Chain creation parameters: what a chain created from this CTM will get.
//!
//! The CTM only stores three hashes (`storedBatchZero`, `initialCutHash`,
//! `initialForceDeploymentHash`), so the parameters themselves are recovered
//! from the `NewChainCreationParams` event and then bound back to those
//! hashes. If the recomputation matches, the decoded event *is* the live
//! configuration and every field below can be checked against it.

use std::collections::HashSet;

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
) -> anyhow::Result<ChainCreationParams> {
    let filter = Filter::new()
        .address(ctm)
        .event_signature(IEcosystemEvents::NewChainCreationParams::SIGNATURE_HASH)
        .from_block(from_block);
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
    /// Length matches and the artifact is byte-identical once CBOR metadata is
    /// blanked, but the hashes differ — because they are taken over bytecode
    /// that *includes* the metadata trailer. Consistent with the branch, but
    /// not independently reproducible without the deployer's exact build.
    MetadataOnly,
    /// Length differs, or the code is a different contract.
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
pub fn verify_bytecode_info(
    index: &ArtifactIndex,
    artifact_name: &str,
    on_chain: &BytecodeInfo,
) -> BytecodeInfoVerdict {
    let Some(artifact) = index.get(artifact_name) else {
        return BytecodeInfoVerdict::MissingArtifact;
    };
    let local = BytecodeInfo::of(&artifact.deployed_code);
    if local == *on_chain {
        return BytecodeInfoVerdict::Exact;
    }
    // Same length plus a metadata-only difference is the signature of a build
    // whose executable bytes agree; anything else is a real divergence.
    if local.length == on_chain.length
        && matches!(
            artifact.compare(&artifact.deployed_code),
            Some(CodeMatch::Exact)
        )
    {
        return BytecodeInfoVerdict::MetadataOnly;
    }
    BytecodeInfoVerdict::Mismatch { local }
}

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
