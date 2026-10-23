use crate::{p2_hash2, p2_hash3};
use crate::chain_registry_constants::{CHAIN_REGISTRY_DEPTH, CHAIN_REGISTRY_LEAF_TAG};

pub fn assert_chain_member(chain: Field, index: u32, path: [Field; CHAIN_REGISTRY_DEPTH], root: Field, count: u64) {
    assert((chain != 0) & ((index as u64) < count), "leg source is not a ZKIP chain");
    let bits: [bool; CHAIN_REGISTRY_DEPTH] = (index as Field).to_le_bits();
    let mut node = p2_hash3(CHAIN_REGISTRY_LEAF_TAG, chain, 0);
    for level in 0..CHAIN_REGISTRY_DEPTH {
        node = if bits[level] { p2_hash2(path[level], node) } else { p2_hash2(node, path[level]) };
    }
    assert(node == root, "leg source is not a ZKIP chain");
}
