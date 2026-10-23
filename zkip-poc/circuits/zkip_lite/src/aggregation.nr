use crate::{field_word_lanes, hi_lo, keccak_lanes, lanes_to_bytes};
use crate::aggregation_constants::{AGG_DIGEST_INPUTS, AGG_SLOT_INPUTS, STATEMENT_DOMAIN};

pub fn statement_digest(vk_commitment: Field, public_inputs: [Field; AGG_SLOT_INPUTS]) -> [Field; AGG_DIGEST_INPUTS] {
    let mut words: [u64; (AGG_SLOT_INPUTS + 2) * 4] = [0; (AGG_SLOT_INPUTS + 2) * 4];
    let vk = field_word_lanes(vk_commitment);
    for j in 0..4 {
        words[j] = STATEMENT_DOMAIN[j];
        words[4 + j] = vk[j];
    }
    for i in 0..AGG_SLOT_INPUTS {
        let input = field_word_lanes(public_inputs[i]);
        for j in 0..4 {
            words[(i + 2) * 4 + j] = input[j];
        }
    }
    let (hi, lo) = hi_lo(lanes_to_bytes(keccak_lanes(words)));
    [hi, lo]
}

#[test]
fn statement_digest_matches_evm_encoding() {
    let mut inputs: [Field; AGG_SLOT_INPUTS] = [0; AGG_SLOT_INPUTS];
    inputs[1] = 1;
    inputs[2] = 2;
    inputs[3] = 3;
    inputs[4] = -1;
    assert(statement_digest(-1, inputs) == [
        236001691962661036957574801616986452024,
        40288098705349719553134111251457184439,
    ]);
}
