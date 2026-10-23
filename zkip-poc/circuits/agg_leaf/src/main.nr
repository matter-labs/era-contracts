use zkip_lite::{
    AGG_PROOF_LEN, AGG_PROOF_TYPE_HONK_ZK, AGG_SLOT_INPUTS, AGG_SLOTS, AGG_VK_LEN,
    aggregation_node, hi_lo, lanes_to_bytes, p2_hash_many, root_from_halves, statement_digest,
};

fn main(
    base_vk: pub Field,
    fold_vk: pub Field,
    statement_count: pub u64,
    height: pub u32,
    vks: [[Field; AGG_VK_LEN]; AGG_SLOTS],
    key_hashes: [Field; AGG_SLOTS],
    proofs: [[Field; AGG_PROOF_LEN]; AGG_SLOTS],
    slot_pis: [[Field; AGG_SLOT_INPUTS]; AGG_SLOTS],
) -> pub [Field; 2] {
    assert(height == 0, "aggregation base height");
    assert((base_vk != 0) & (fold_vk != 0), "aggregation key set");
    assert((statement_count > 0) & (statement_count <= AGG_SLOTS as u64), "aggregation base count");
    let mut leaves = [[0; 4]; AGG_SLOTS];
    for i in 0..AGG_SLOTS {
        std::verify_proof_with_type(vks[i], proofs[i], slot_pis[i], key_hashes[i], AGG_PROOF_TYPE_HONK_ZK);
        let digest = statement_digest(p2_hash_many(vks[i]), slot_pis[i]);
        if (i as u64) < statement_count {
            leaves[i] = root_from_halves(digest[0], digest[1]);
        }
    }
    let (hi, lo) = hi_lo(lanes_to_bytes(aggregation_node(leaves, true)));
    [hi, lo]
}
