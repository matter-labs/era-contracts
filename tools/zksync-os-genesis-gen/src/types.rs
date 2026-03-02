use std::collections::BTreeMap;

use alloy::primitives::{Address, FixedBytes, B256};

use blake2::{Blake2s256, Digest};

/// The depth of the Merkle tree used for the genesis state.
pub const MERKLE_TREE_DEPTH: usize = 64;

#[derive(serde::Serialize, serde::Deserialize, Debug, Clone)]
pub struct InitialGenesisInput {
    /// Initial contracts to deploy in genesis.
    /// Storage entries that set the contracts as deployed and preimages will be derived from this field.
    pub initial_contracts: Vec<(Address, alloy::primitives::Bytes)>,

    /// "Pretty" additional storage in address -> key -> value form.
    /// Keys and values must be 32 bytes (B256).
    /// Example:
    /// {
    ///   "0x...1000c": { "0x00..00": "0x...800f" },
    ///   "0x...800f": {
    ///     "0x3608...2bbc": "0x504c4a...f87",
    ///     "0xb531...6103": "0x0000...1000c"
    ///   }
    /// }
    pub additional_storage: BTreeMap<Address, BTreeMap<B256, B256>>,

    /// Raw (already flattened) additional storage, kept for backward compatibility.
    /// Same format as before.
    #[serde(skip)]
    pub additional_storage_raw: Vec<(B256, B256)>,
}

/// A leaf in the genesis state Merkle tree.
///
/// The tree is of depth 64, and each leaf contains:
/// - `key`: the storage key (B256)
/// - `value`: the storage value (B256)
/// - `next_index`: the index of the leaf with the next largest key (u64)
///
/// The initial leaves are:
/// - The minimal leaf (key = 0, value = 0, next_index = 2)
/// - The maximal leaf (key = MAX_B256_VALUE, value = 0, next_index = 1), which points to itself
///
/// All other leaves are sorted by key, and their `next_index` points to the next leaf in key order.
#[derive(Debug)]
pub struct LeafInfo {
    pub key: B256,
    pub value: B256,
    pub next_index: u64,
}

impl LeafInfo {
    pub fn new(key: B256, value: B256, next_index: u64) -> Self {
        Self {
            key,
            value,
            next_index,
        }
    }

    /// Hashes the leaf as blake2s256(key || value || next_index_le)
    pub fn hash_leaf(&self) -> B256 {
        let mut hashed_bytes = [0; 2 * 32 + 8];
        hashed_bytes[..32].copy_from_slice(self.key.as_slice());
        hashed_bytes[32..64].copy_from_slice(self.value.as_slice());
        hashed_bytes[64..].copy_from_slice(&self.next_index.to_le_bytes());
        B256::from_slice(&Blake2s256::digest(&hashed_bytes))
    }
}

/// The maximal possible B256 value (all bytes set to 0xFF).
pub const MAX_B256_VALUE: B256 = FixedBytes::<32>([0xFF; 32]);

#[derive(serde::Serialize, serde::Deserialize, Debug)]
pub struct Genesis {
    #[serde(flatten)]
    pub initial_genesis: InitialGenesisInput,
    pub genesis_root: B256,
    pub protocol_semantic_version: ProtocolVersion,
    /// Execution version used for genesis.
    pub execution_version: u32,
    #[serde(flatten)]
    pub other: serde_json::Value,
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
    pub patch: u16,
}
