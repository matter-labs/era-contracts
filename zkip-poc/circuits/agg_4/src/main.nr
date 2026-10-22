// Cross-chain aggregation of ZKIP proofs: one L1 verification for up to four chains' statements.
//
// Each slot recursively verifies one zero-knowledge UltraHonk proof (noir-recursive target) of an aggregatable
// ZKIP circuit: debit_4, claim_1 or claim_2, all with 16 public inputs. The slot's inner public inputs are public
// here, and so is a Poseidon2 commitment to the verification key the slot was checked against; L1 applies a slot
// only if that commitment belongs to an approved circuit of the slot's kind. Unused slots repeat a real proof and
// L1 ignores them.
use zkip_lite::p2_hash_many;

global SLOTS: u32 = 4;
global VK_LEN: u32 = 115;
global PROOF_LEN: u32 = 458; // RECURSIVE_ZK_PROOF_LENGTH in bb v5.2.1
global NPI: u32 = 16;
global PROOF_TYPE_HONK_ZK: u32 = 6;

fn main(
    vks: [[Field; VK_LEN]; SLOTS],
    key_hashes: [Field; SLOTS],
    proofs: [[Field; PROOF_LEN]; SLOTS],
    slot_pis: pub [[Field; NPI]; SLOTS],
) -> pub [Field; SLOTS] {
    let mut vk_commits: [Field; SLOTS] = [0; SLOTS];
    for i in 0..SLOTS {
        std::verify_proof_with_type(vks[i], proofs[i], slot_pis[i], key_hashes[i], PROOF_TYPE_HONK_ZK);
        vk_commits[i] = p2_hash_many(vks[i]);
    }
    vk_commits
}
