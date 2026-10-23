use zkip_lite::{
    AGG_PROOF_LEN, AGG_VK_LEN, RECURSIVE_NODE_INPUTS, hi_lo, lanes_to_bytes, verify_aggregation_node,
};

fn main(
    base_vk: pub Field,
    fold_vk: pub Field,
    statement_count: pub u64,
    height: pub u32,
    vk: [Field; AGG_VK_LEN],
    key_hash: Field,
    proof: [Field; AGG_PROOF_LEN],
    node_pis: [Field; RECURSIVE_NODE_INPUTS],
) -> pub [Field; 2] {
    assert(statement_count > 0, "empty settlement");
    let (root, count) = verify_aggregation_node(vk, proof, node_pis, key_hash, base_vk, fold_vk, height);
    assert(count == statement_count, "aggregation final count");
    let (hi, lo) = hi_lo(lanes_to_bytes(root));
    [hi, lo]
}
