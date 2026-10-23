use crate::{keccak_lanes, p2_hash_many, root_from_halves};
use crate::aggregation_constants::{
    AGG_PROOF_LEN, AGG_PROOF_TYPE_HONK_ZK, AGG_SLOTS, AGG_VK_LEN, RECURSIVE_MAX_HEIGHT,
    RECURSIVE_NODE_INPUTS, AGGREGATION_BASE_DOMAIN, AGGREGATION_FOLD_DOMAIN,
};

pub fn aggregation_node(children: [[u64; 4]; AGG_SLOTS], base: bool) -> [u64; 4] {
    let mut words = [0; (AGG_SLOTS + 1) * 4];
    let domain = if base { AGGREGATION_BASE_DOMAIN } else { AGGREGATION_FOLD_DOMAIN };
    for j in 0..4 {
        words[j] = domain[j];
    }
    for i in 0..AGG_SLOTS {
        for j in 0..4 {
            words[(i + 1) * 4 + j] = children[i][j];
        }
    }
    keccak_lanes(words)
}

pub fn verify_aggregation_node(
    vk: [Field; AGG_VK_LEN],
    proof: [Field; AGG_PROOF_LEN],
    inputs: [Field; RECURSIVE_NODE_INPUTS],
    key_hash: Field,
    base_vk: Field,
    fold_vk: Field,
    height: u32,
) -> ([u64; 4], u64) {
    assert(height <= RECURSIVE_MAX_HEIGHT, "aggregation height");
    assert((inputs[0] == base_vk) & (inputs[1] == fold_vk), "aggregation key set");
    assert(inputs[3] == height as Field, "aggregation child height");
    let approved_vk = if height == 0 { base_vk } else { fold_vk };
    assert(p2_hash_many(vk) == approved_vk, "aggregation child key");
    std::verify_proof_with_type(vk, proof, inputs, key_hash, AGG_PROOF_TYPE_HONK_ZK);
    let count = inputs[2] as u64;
    assert(count as Field == inputs[2], "aggregation count width");
    (root_from_halves(inputs[4], inputs[5]), count)
}
