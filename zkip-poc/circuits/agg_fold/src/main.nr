use zkip_lite::{
    AGG_PROOF_LEN, AGG_SLOTS, AGG_VK_LEN, RECURSIVE_MAX_HEIGHT, RECURSIVE_NODE_INPUTS,
    aggregation_node, hi_lo, lanes_to_bytes, verify_aggregation_node,
};

fn main(
    base_vk: pub Field,
    fold_vk: pub Field,
    statement_count: pub u64,
    height: pub u32,
    active_children: u32,
    vks: [[Field; AGG_VK_LEN]; AGG_SLOTS],
    key_hashes: [Field; AGG_SLOTS],
    proofs: [[Field; AGG_PROOF_LEN]; AGG_SLOTS],
    child_pis: [[Field; RECURSIVE_NODE_INPUTS]; AGG_SLOTS],
) -> pub [Field; 2] {
    assert(height > 0 & height <= RECURSIVE_MAX_HEIGHT, "aggregation fold height");
    assert((active_children > 0) & (active_children <= AGG_SLOTS), "aggregation child count");
    let mut roots = [[0; 4]; AGG_SLOTS];
    let mut count = 0u64;
    let mut max_height = 0u32;
    for i in 0..AGG_SLOTS {
        let child_height = child_pis[i][3] as u32;
        let (root, child_count) = verify_aggregation_node(
            vks[i], proofs[i], child_pis[i], key_hashes[i], base_vk, fold_vk, child_height,
        );
        if i < active_children {
            if child_height > max_height {
                max_height = child_height;
            }
            roots[i] = root;
            count += child_count;
        }
    }
    assert(count == statement_count, "aggregation fold count");
    assert(height == max_height + 1, "aggregation fold depth");
    let (hi, lo) = hi_lo(lanes_to_bytes(aggregation_node(roots, false)));
    [hi, lo]
}
