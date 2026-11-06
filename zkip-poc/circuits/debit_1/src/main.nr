// Batch-debit proof: gates execution of a batch that appended legs to the chain's IMT. Opens every new
// commit value (L1 hands them in, after checking the IMT insertion proofs) and debits the interop
// balance; applies an optional public lock from the L1 cap.
use zkip_lite::{apply_delta, hi_lo, lanes_to_bytes, open_leg, State, state_root, BUNDLE_LEN, MAX_ASSETS, PRE_LEN};

global N: u32 = 1;
global TWO_POW_128: Field = 340282366920938463463374607431768211456;

fn main(
    chain_id: pub Field,
    l1_chain_id: pub Field,
    prev_state_root: pub Field,
    new_state_root: pub Field,
    num_legs: pub u32,
    cv_hi: pub [Field; N],
    cv_lo: pub [Field; N],
    lock_asset_hi: pub Field,
    lock_asset_lo: pub Field,
    lock_amount: pub Field,
    bal_asset: [Field; MAX_ASSETS],
    bal_amount: [Field; MAX_ASSETS],
    null_root: Field,
    null_size: Field,
    bundles: [[u8; BUNDLE_LEN]; N],
    preimages: [[u8; PRE_LEN]; N],
    leg_index: [bool; N],
    slots: [u32; N],
    lock_slot: u32,
) {
    let mut st = State { bal_asset, bal_amount, null_root, null_size };
    assert(state_root(st) == prev_state_root, "previous state");
    assert((num_legs >= 1) & (num_legs <= N), "leg count");
    if lock_amount != 0 {
        lock_amount.assert_max_bit_size::<128>();
        apply_delta(&mut st, lock_slot, lock_asset_hi * TWO_POW_128 + lock_asset_lo, lock_amount, true);
    }
    for k in 0..N {
        let o = open_leg(bundles[k], preimages[k], leg_index[k], l1_chain_id);
        if k < num_legs {
            let own_src = if leg_index[k] { o.leg_src[1] } else { o.leg_src[0] };
            assert(own_src == chain_id, "leg is not from this chain");
            assert(o.dst != l1_chain_id, "leg to L1");
            let own_cv = if leg_index[k] { o.cv[1] } else { o.cv[0] };
            let (hi, lo) = hi_lo(lanes_to_bytes(own_cv));
            assert(hi == cv_hi[k], "commit value hi");
            assert(lo == cv_lo[k], "commit value lo");
            if o.origin_chain != chain_id {
                apply_delta(&mut st, slots[k], o.asset_key, o.amount, false);
            }
        } else {
            assert((cv_hi[k] == 0) & (cv_lo[k] == 0), "unused commit value slot");
        }
    }
    assert(state_root(st) == new_state_root, "new state");
}
