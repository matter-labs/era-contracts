// Wrap four agg_4 proofs. The approved child key is public; L1 checks it before accepting the wrapper.
use zkip_lite::{
    AGG_DIGEST_INPUTS, AGG_LARGE_SLOTS, AGG_PROOF_LEN, AGG_PROOF_TYPE_HONK_ZK, AGG_SLOTS,
    AGG_VK_LEN, p2_hash_many,
};

fn main(
    child_vk_commitment: pub Field,
    vks: [[Field; AGG_VK_LEN]; AGG_SLOTS],
    key_hashes: [Field; AGG_SLOTS],
    proofs: [[Field; AGG_PROOF_LEN]; AGG_SLOTS],
    child_pis: [[Field; AGG_SLOTS * AGG_DIGEST_INPUTS]; AGG_SLOTS],
) -> pub [Field; AGG_LARGE_SLOTS * AGG_DIGEST_INPUTS] {
    let mut digests = [0; AGG_LARGE_SLOTS * AGG_DIGEST_INPUTS];
    for i in 0..AGG_SLOTS {
        assert(p2_hash_many(vks[i]) == child_vk_commitment, "unapproved child key");
        std::verify_proof_with_type(vks[i], proofs[i], child_pis[i], key_hashes[i], AGG_PROOF_TYPE_HONK_ZK);
        for j in 0..AGG_SLOTS * AGG_DIGEST_INPUTS {
            digests[i * AGG_SLOTS * AGG_DIGEST_INPUTS + j] = child_pis[i][j];
        }
    }
    digests
}
