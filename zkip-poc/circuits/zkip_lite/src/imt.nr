use crate::{bytes_to_lanes, hi_lo, lanes_to_bytes, merkle_var, protocol_hash_lanes, D_IMT};
use crate::imt_constants::{IMT_MAX_LEAVES, IMT_ZEROS};

pub fn root_from_halves(_hi: Field, _lo: Field) -> [u64; 4] {
    let hi: [u8; 16] = _hi.to_be_bytes();
    let lo: [u8; 16] = _lo.to_be_bytes();
    let mut bytes = [0; 32];
    for i in 0..16 { bytes[i] = hi[i]; bytes[16 + i] = lo[i]; }
    bytes_to_lanes::<32, 4>(bytes)
}

fn less(_a: [u64; 4], _b: [u64; 4]) -> bool {
    let (ah, al) = hi_lo(lanes_to_bytes(_a));
    let (bh, bl) = hi_lo(lanes_to_bytes(_b));
    ah.lt(bh) | ((ah == bh) & al.lt(bl))
}

fn height(_count: u32) -> u32 {
    let mut result = 0;
    for i in 0..D_IMT {
        if _count > (1 << i) { result = i + 1; }
    }
    result
}

fn leaf_hash(_value: [u64; 4], _next_index: [u64; 4], _next_value: [u64; 4]) -> [u64; 4] {
    protocol_hash_lanes([
        _value[0], _value[1], _value[2], _value[3],
        _next_index[0], _next_index[1], _next_index[2], _next_index[3],
        _next_value[0], _next_value[1], _next_value[2], _next_value[3],
    ])
}

pub fn insert(
    _root: [u64; 4],
    _count: u32,
    _value: [u64; 4],
    _low_value: [u64; 4],
    _low_next_index: [u64; 4],
    _low_next_value: [u64; 4],
    _low_index: u32,
    _low_path: [[u64; 4]; D_IMT],
    _new_path: [[u64; 4]; D_IMT],
) -> [u64; 4] {
    assert((_count >= 1) & (_count < IMT_MAX_LEAVES), "IMT capacity");
    assert(_low_index < _count, "IMT low index");
    assert(_value != [0; 4], "IMT zero value");
    assert(less(_low_value, _value), "IMT predecessor order");
    assert((_low_next_value == [0; 4]) | less(_value, _low_next_value), "IMT duplicate or successor order");
    let before = height(_count);
    let after = height(_count + 1);
    let low_leaf = leaf_hash(_low_value, _low_next_index, _low_next_value);
    assert(merkle_var(low_leaf, _low_index as Field, _low_path, before) == _root, "IMT predecessor root");
    let index_word = bytes_to_lanes::<32, 4>((_count as Field).to_be_bytes::<32>());
    let updated_leaf = leaf_hash(_low_value, index_word, _value);
    let updated = merkle_var(updated_leaf, _low_index as Field, _low_path, before);
    let grown = if after > before { crate::keccak_pair(updated, IMT_ZEROS[before]) } else { updated };
    assert(merkle_var(IMT_ZEROS[0], _count as Field, _new_path, after) == grown, "IMT append slot");
    merkle_var(leaf_hash(_value, _low_next_index, _low_next_value), _count as Field, _new_path, after)
}
