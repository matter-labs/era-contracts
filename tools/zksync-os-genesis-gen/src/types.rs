use std::collections::BTreeMap;

use alloy::primitives::{Address, Bloom, FixedBytes, B256, B64, U256};
use alloy::consensus::{EMPTY_OMMER_ROOT_HASH, Header};
use alloy::eips::eip1559::INITIAL_BASE_FEE;

use blake2::{Blake2s256, Digest};
use serde::{Deserialize, Serialize};
use zk_os_api::helpers::{set_properties_code, set_properties_nonce};
use zk_os_basic_system::system_implementation::flat_storage_model::{AccountProperties, ACCOUNT_PROPERTIES_STORAGE_ADDRESS};

/// The depth of the Merkle tree used for the genesis state.
const MERKLE_TREE_DEPTH: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FullGenesis {
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
    #[serde(default)]
    pub additional_storage: BTreeMap<Address, BTreeMap<B256, B256>>,

    /// Raw (already flattened) additional storage, kept for backward compatibility.
    /// Same format as before.
    #[serde(default)]
    pub additional_storage_raw: Vec<(B256, B256)>,

    /// Execution version used for genesis.
    pub execution_version: u32,
    /// The expected root hash of the genesis state.
    pub genesis_root: B256,
}

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
    pub additional_storage_raw: Vec<(B256, B256)>,

    /// Execution version used for genesis.
    pub execution_version: u32,
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
struct LeafInfo {
    key: B256,
    value: B256,
    next_index: u64,
}

impl LeafInfo {
    fn new(key: B256, value: B256, next_index: u64) -> Self {
        Self { key, value, next_index }
    }

    /// Hashes the leaf as blake2s256(key || value || next_index_le)
    fn hash_leaf(&self) -> B256 {
        let mut hashed_bytes = [0; 2 * 32 + 8];
        hashed_bytes[..32].copy_from_slice(self.key.as_slice());
        hashed_bytes[32..64].copy_from_slice(self.value.as_slice());
        hashed_bytes[64..].copy_from_slice(&self.next_index.to_le_bytes());
        B256::from_slice(&Blake2s256::digest(&hashed_bytes))
    }
}


/// The maximal possible B256 value (all bytes set to 0xFF).
const MAX_B256_VALUE: B256 = FixedBytes::<32>([0xFF; 32]);


/// Calculates the Merkle root of a tree of given depth from the provided leaves.
///
/// The tree is filled with the given leaves, and empty leaves are filled with the hash of a zero leaf.
fn calculate_merkle_root(tree_depth: usize, logs: &[LeafInfo]) -> anyhow::Result<B256> {
    // Hash all leaves
    let mut nodes: Vec<B256> = logs.iter().map(LeafInfo::hash_leaf).collect();
    let mut empty_subtree_hash = LeafInfo::new(B256::ZERO, B256::ZERO, 0).hash_leaf();

    for _level in 0..tree_depth {
        // Pair up nodes, hash each pair, fill with empty hash if odd
        nodes = nodes
            .chunks(2)
            .map(|chunk| {
                let lhs = chunk[0];
                let rhs = if chunk.len() > 1 { chunk[1] } else { empty_subtree_hash };
                let mut branch_data = [0; 64];
                branch_data[..32].copy_from_slice(lhs.as_slice());
                branch_data[32..].copy_from_slice(rhs.as_slice());
                B256::from_slice(&Blake2s256::digest(&branch_data))
            })
            .collect();

        // Update the empty subtree hash for this level
        let mut branch_data = [0; 64];
        branch_data[..32].copy_from_slice(empty_subtree_hash.as_slice());
        branch_data[32..].copy_from_slice(empty_subtree_hash.as_slice());
        empty_subtree_hash = B256::from_slice(&Blake2s256::digest(&branch_data));
    }

    if nodes.len() > 1 {
        anyhow::bail!("Merkle reduction did not collapse to a single root (len={}).", nodes.len());
    }

    return Ok(nodes[0]);
}


/// Builds the initial genesis root for the state tree.
///
/// The tree is of depth 64. The first two leaves are:
/// - Minimal leaf: key = 0, value = 0, next_index = 2
/// - Maximal leaf: key = MAX_B256_VALUE, value = 0, next_index = 1 (points to itself)
///
/// All other leaves are sorted by key, and their `next_index` points to the next leaf in key order.
fn build_initial_genesis_root(initial_storage_logs: BTreeMap<B256, B256>) -> anyhow::Result<(B256, u64)> {
    let total_provided_logs = initial_storage_logs.len();
    // Enumerate and build leaves for provided logs
    let provided_leaves: Vec<LeafInfo> = initial_storage_logs
        .into_iter()
        .enumerate()
        .map(|(num, (k, v))| {
            let next_leaf = if num == total_provided_logs - 1 { 1 } else { num as u64 + 3 };
            LeafInfo::new(k, v, next_leaf)
        })
        .collect();

    // The initial leaves: minimal and maximal
    let mut leaves = vec![
        LeafInfo::new(B256::ZERO, B256::ZERO, 2),
        LeafInfo::new(MAX_B256_VALUE, B256::ZERO, 1),
    ];
    leaves.extend(provided_leaves);

    let total_leaves = leaves.len() as u64;
    Ok((calculate_merkle_root(MERKLE_TREE_DEPTH, &leaves)?, total_leaves))
}

fn build_initial_genesis_commitment(
    initial_storage_logs: BTreeMap<B256, B256>,
    genesis_block: Header
) -> anyhow::Result<B256> {
    let (genesis_root, leaves_count) = build_initial_genesis_root(initial_storage_logs)?;
    let number = 0u64;
    let timestamp = 0u64;

    let last_256_block_hashes_blake = {
        let mut blocks_hasher = Blake2s256::new();
        for _ in 0..255 {
            blocks_hasher.update([0u8; 32]);
        }
        blocks_hasher.update(genesis_block.hash_slow());

        blocks_hasher.finalize()
    };

    let mut hasher = Blake2s256::new();
    hasher.update(genesis_root.as_slice());
    hasher.update(leaves_count.to_be_bytes());
    hasher.update(number.to_be_bytes());
    hasher.update(last_256_block_hashes_blake);
    hasher.update(timestamp.to_be_bytes());
    let state_commitment = B256::from_slice(&hasher.finalize());
    Ok(state_commitment)
}

fn flat_storage_key_for_contract(address: Address, key: B256) -> B256 {
    // Flat key = blake2s256( pad32(address) || key )
    let mut bytes = [0u8; 64];
    // first 32 bytes: address left-padded into the last 20 bytes
    bytes[12..32].copy_from_slice(address.as_slice());
    // second 32 bytes: the full storage slot key
    bytes[32..64].copy_from_slice(key.as_slice());
    B256::from_slice(&Blake2s256::digest(bytes))
}

fn account_properties_flat_key(address: Address) -> B256 {
    let mut bytes = [0u8; 32];
    bytes[12..32].copy_from_slice(&address.as_slice());

    flat_storage_key_for_contract(ACCOUNT_PROPERTIES_STORAGE_ADDRESS.to_be_bytes().into(), bytes.into())
}

pub fn build_genesis(genesis_input: InitialGenesisInput) -> anyhow::Result<FullGenesis> {
    // BTreeMap is used to ensure that the storage logs are sorted by key, so that the order is deterministic
    // which is important for tree.
    let mut storage_logs: BTreeMap<B256, B256> = BTreeMap::new();

    for (address, deployed_code) in genesis_input.initial_contracts.iter() {
        let mut account_properties = AccountProperties::default();
        // When contracts are deployed, they have a nonce of 1.
        set_properties_nonce(&mut account_properties, 1);
        set_properties_code(&mut account_properties, &deployed_code);

        let flat_storage_key = account_properties_flat_key(*address);
        let account_properties_hash = account_properties.compute_hash();
        storage_logs.insert(
            flat_storage_key,
            account_properties_hash.as_u8_array().into(),
        );
    }

    // 1) Insert RAW additional storage first
    for (key, value) in genesis_input.additional_storage_raw.iter() {
        let duplicate = storage_logs.insert(*key, *value).is_some();
        if duplicate {
            anyhow::bail!("Genesis input contains duplicate storage key in additional_storage_raw: {key:?}");
        }
    }

    // 2) Flatten and insert "pretty" additional storage (address -> key -> value).
    for (address, slots) in genesis_input.additional_storage.iter() {
        for (slot_key, value_b256) in slots {
            let flat_key = flat_storage_key_for_contract(*address, *slot_key);

            let duplicate = storage_logs.insert(flat_key, *value_b256).is_some();
            if duplicate {
                anyhow::bail!(
                    "Genesis input contains duplicate flattened storage key derived from address {address:?}, slot {slot_key:?}. \
                     This likely conflicts with additional_storage_raw."
                );
            }
        }
    }

    let header = Header {
        parent_hash: B256::ZERO,
        ommers_hash: EMPTY_OMMER_ROOT_HASH,
        beneficiary: Address::ZERO,
        // for now state root is zero
        state_root: B256::ZERO,
        transactions_root: B256::ZERO,
        receipts_root: B256::ZERO,
        logs_bloom: Bloom::ZERO,
        difficulty: U256::ZERO,
        number: 0,
        gas_limit: 5_000,
        gas_used: 0,
        timestamp: 0,
        extra_data: Default::default(),
        mix_hash: B256::ZERO,
        nonce: B64::ZERO,
        base_fee_per_gas: Some(INITIAL_BASE_FEE),
        withdrawals_root: None,
        blob_gas_used: None,
        excess_blob_gas: None,
        parent_beacon_block_root: None,
        requests_hash: None,
    };

    Ok(FullGenesis {
        initial_contracts: genesis_input.initial_contracts,
        additional_storage: genesis_input.additional_storage,
        additional_storage_raw: genesis_input.additional_storage_raw,
        execution_version: genesis_input.execution_version,
        genesis_root: build_initial_genesis_commitment(storage_logs, header)?,
    })
}