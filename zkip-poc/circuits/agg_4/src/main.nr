// Cross-chain aggregation of ZKIP proofs: one L1 verification for up to four chains' statements.
//
// Each slot recursively verifies one zero-knowledge UltraHonk proof (noir-recursive target) of an aggregatable
// ZKIP circuit: debit_1, debit_4, claim_1 or claim_2, all with 16 public inputs. Each public digest binds those inputs
// and the Poseidon2 commitment to the recursively verified key. See protocol-docs/zkip-accounting-poc.md.
use zkip_lite::{
    AGG_DIGEST_INPUTS, AGG_PROOF_LEN, AGG_PROOF_TYPE_HONK_ZK, AGG_SLOT_INPUTS, AGG_SLOTS,
    AGG_VK_LEN, p2_hash_many, statement_digest,
};

fn main(
    vks: [[Field; AGG_VK_LEN]; AGG_SLOTS],
    key_hashes: [Field; AGG_SLOTS],
    proofs: [[Field; AGG_PROOF_LEN]; AGG_SLOTS],
    slot_pis: [[Field; AGG_SLOT_INPUTS]; AGG_SLOTS],
) -> pub [[Field; AGG_DIGEST_INPUTS]; AGG_SLOTS] {
    let mut digests = [[0; AGG_DIGEST_INPUTS]; AGG_SLOTS];
    for i in 0..AGG_SLOTS {
        std::verify_proof_with_type(vks[i], proofs[i], slot_pis[i], key_hashes[i], AGG_PROOF_TYPE_HONK_ZK);
        digests[i] = statement_digest(p2_hash_many(vks[i]), slot_pis[i]);
    }
    digests
}
