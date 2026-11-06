// Claim proof (asynchronous): credits legs sent to this chain once their flow is final, proved
// in-circuit against L1 message roots the registry supplies as anchors (no interop-graph leak), and
// applies an optional public unlock back to the L1 cap.
use zkip_lite::{
    apply_delta, cv_key, hi_lo, lanes_to_bytes, null_insert, open_leg, shared_root, State, state_root,
    BUNDLE_LEN, D_CHAIN, D_IMT, D_SHARED, MAX_ASSETS, NULL_DEPTH, NUM_ANCHORS, NUM_ZKIP_CHAINS, PRE_LEN,
};

global N: u32 = 1;
global TWO_POW_128: Field = 340282366920938463463374607431768211456;

fn main(
    chain_id: pub Field,
    l1_chain_id: pub Field,
    prev_state_root: pub Field,
    new_state_root: pub Field,
    num_credits: pub u32,
    anchor_hi: pub [Field; NUM_ANCHORS],
    anchor_lo: pub [Field; NUM_ANCHORS],
    zkip_chains: pub [Field; NUM_ZKIP_CHAINS],
    unlock_asset_hi: pub Field,
    unlock_asset_lo: pub Field,
    unlock_amount: pub Field,
    bal_asset: [Field; MAX_ASSETS],
    bal_amount: [Field; MAX_ASSETS],
    null_root: Field,
    null_size: Field,
    bundles: [[u8; BUNDLE_LEN]; N],
    preimages: [[u8; PRE_LEN]; N],
    credit_leg: [bool; N],
    slots: [u32; N],
    unlock_slot: u32,
    imt_next_index: [[[u64; 4]; 2]; N],
    imt_next_value: [[[u64; 4]; 2]; N],
    imt_index: [[Field; 2]; N],
    imt_height: [[u32; 2]; N],
    imt_path: [[[[u64; 4]; D_IMT]; 2]; N],
    cbr_begin: [[[u64; 4]; 2]; N],
    cbr_left: [[[u64; 4]; 2]; N],
    batch_number: [[Field; 2]; N],
    batch_ts: [[u64; 2]; N],
    chain_height: [[u32; 2]; N],
    chain_path: [[[[u64; 4]; D_CHAIN]; 2]; N],
    shared_index: [[Field; 2]; N],
    shared_height: [[u32; 2]; N],
    shared_path: [[[[u64; 4]; D_SHARED]; 2]; N],
    anchor_sel: [[u32; 2]; N],
    null_low: [[Field; 3]; N],
    null_low_index: [Field; N],
    null_low_path: [[Field; NULL_DEPTH]; N],
    null_new_path: [[Field; NULL_DEPTH]; N],
) {
    let mut st = State { bal_asset, bal_amount, null_root, null_size };
    assert(state_root(st) == prev_state_root, "previous state");
    assert(num_credits <= N, "credit count");
    for c in 0..N {
        let o = open_leg(bundles[c], preimages[c], credit_leg[c], l1_chain_id);
        for j in 0..2 {
            let root = shared_root(
                o.cv[j],
                o.leg_src[j],
                imt_next_index[c][j],
                imt_next_value[c][j],
                imt_index[c][j],
                imt_height[c][j],
                imt_path[c][j],
                cbr_begin[c][j],
                cbr_left[c][j],
                batch_number[c][j],
                batch_ts[c][j],
                chain_height[c][j],
                chain_path[c][j],
                shared_index[c][j],
                shared_height[c][j],
                shared_path[c][j],
            );
            if c < num_credits {
                let (rh, rl) = hi_lo(lanes_to_bytes(root));
                let sel = anchor_sel[c][j];
                assert(rh == anchor_hi[sel], "leg not under the anchor root (hi)");
                assert(rl == anchor_lo[sel], "leg not under the anchor root (lo)");
                assert(batch_ts[c][j] <= o.deadline, "leg settled after the deadline");
                let mut listed = false;
                for z in 0..NUM_ZKIP_CHAINS {
                    listed = listed | ((zkip_chains[z] == o.leg_src[j]) & (zkip_chains[z] != 0));
                }
                assert(listed, "leg source is not a ZKIP chain");
            }
        }
        if c < num_credits {
            assert(o.dst == chain_id, "bundle is not to this chain");
            let credited_src = if credit_leg[c] { o.leg_src[1] } else { o.leg_src[0] };
            assert(credited_src != chain_id, "own leg");
            let cv = if credit_leg[c] { o.cv[1] } else { o.cv[0] };
            null_insert(&mut st, cv_key(cv), null_low[c], null_low_index[c], null_low_path[c], null_new_path[c]);
            if o.origin_chain != chain_id {
                apply_delta(&mut st, slots[c], o.asset_key, o.amount, true);
            }
        }
    }
    if unlock_amount != 0 {
        unlock_amount.assert_max_bit_size::<128>();
        apply_delta(&mut st, unlock_slot, unlock_asset_hi * TWO_POW_128 + unlock_asset_lo, unlock_amount, false);
    }
    assert(state_root(st) == new_state_root, "new state");
}
