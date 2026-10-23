// Proves that every IMT insertion between the batch roots debits its authenticated transfer.
use zkip_lite::{apply_delta, imt_insert, root_from_halves, open_leg, State, state_root, BUNDLE_LEN, D_IMT, IMT_MAX_LEAVES, MAX_ASSETS, PRE_LEN};

global N: u32 = 4;
global TWO_POW_128: Field = 340282366920938463463374607431768211456;

fn main(
    chain_id: pub Field,
    l1_chain_id: pub Field,
    prev_state_root: pub Field,
    new_state_root: pub Field,
    num_legs: pub u32,
    imt_begin_hi: pub Field,
    imt_begin_lo: pub Field,
    imt_end_hi: pub Field,
    imt_end_lo: pub Field,
    leaf_count: pub u32,
    lock_asset_hi: pub Field,
    lock_asset_lo: pub Field,
    lock_amount: pub Field,
    reserved: pub [Field; 3],
    bal_asset: [Field; MAX_ASSETS],
    bal_amount: [Field; MAX_ASSETS],
    null_root: Field,
    null_size: Field,
    bundles: [[u8; BUNDLE_LEN]; N],
    preimages: [[u8; PRE_LEN]; N],
    leg_index: [bool; N],
    slots: [u32; N],
    lock_slot: u32,
    insert_low_value: [[u64; 4]; N],
    insert_low_next_index: [[u64; 4]; N],
    insert_low_next_value: [[u64; 4]; N],
    insert_low_index: [u32; N],
    insert_low_path: [[[u64; 4]; D_IMT]; N],
    insert_new_path: [[[u64; 4]; D_IMT]; N],
) {
    let mut st = State { bal_asset, bal_amount, null_root, null_size };
    assert(state_root(st) == prev_state_root, "previous state");
    assert((num_legs >= 1) & (num_legs <= N), "leg count");
    if lock_amount != 0 {
        lock_amount.assert_max_bit_size::<128>();
        apply_delta(&mut st, lock_slot, lock_asset_hi * TWO_POW_128 + lock_asset_lo, lock_amount, true);
    }
    assert(reserved == [0; 3], "reserved public inputs");
    assert((leaf_count >= 1) & (leaf_count <= IMT_MAX_LEAVES - num_legs), "IMT capacity");
    let mut imt = root_from_halves(imt_begin_hi, imt_begin_lo);
    for k in 0..N {
        let o = open_leg(bundles[k], preimages[k], leg_index[k], l1_chain_id);
        if k < num_legs {
            let own_src = if leg_index[k] { o.leg_src[1] } else { o.leg_src[0] };
            assert(own_src == chain_id, "leg is not from this chain");
            assert(o.dst != l1_chain_id, "leg to L1");
            let own_cv = if leg_index[k] { o.cv[1] } else { o.cv[0] };
            imt = imt_insert(imt, leaf_count + k, own_cv, insert_low_value[k], insert_low_next_index[k],
                insert_low_next_value[k], insert_low_index[k], insert_low_path[k], insert_new_path[k]);
            if o.origin_chain != chain_id {
                apply_delta(&mut st, slots[k], o.asset_key, o.amount, false);
            }
        }
    }
    assert(imt == root_from_halves(imt_end_hi, imt_end_lo), "IMT end root");
    assert(state_root(st) == new_state_root, "new state");
}
