// ZKIP-lite PoC circuits: debits of interop legs and claims of final credits (design: zkip-poc/README.md).
// Hashes of protocol data are keccak and must match this repo's L1 and L2 contracts byte for byte; ZKIP's own
// state is Poseidon2.

mod imt;
mod imt_constants;
mod aggregation;
mod aggregation_constants;
mod recursive_aggregation;
pub use aggregation::statement_digest;
pub use aggregation_constants::{AGG_SLOTS, AGG_SLOT_INPUTS, AGG_DIGEST_INPUTS};
pub use aggregation_constants::{AGG_LARGE_SLOTS, AGG_VK_LEN, AGG_PROOF_LEN, AGG_PROOF_TYPE_HONK_ZK};
pub use aggregation_constants::{RECURSIVE_NODE_INPUTS, RECURSIVE_MAX_HEIGHT};
pub use recursive_aggregation::{aggregation_node, verify_aggregation_node};
pub use imt::{insert as imt_insert, root_from_halves};
pub use imt_constants::IMT_MAX_LEAVES;

pub global MAX_ASSETS: u32 = 8;
pub global NULL_DEPTH: u32 = 24;
pub global D_IMT: u32 = 16;
pub global D_CHAIN: u32 = 18;
pub global D_SHARED: u32 = 7;
mod chain_registry;
mod chain_registry_constants;
pub use chain_registry::assert_chain_member;
pub use chain_registry_constants::CHAIN_REGISTRY_DEPTH;
pub global NUM_ANCHORS: u32 = 2;
pub global BUNDLE_LEN: u32 = 1600;
pub global PRE_LEN: u32 = 384;
pub global STATE_VERSION: Field = 1;

global TWO_POW_64: Field = 18446744073709551616;
global TWO_POW_128: Field = 340282366920938463463374607431768211456;
global VERSION_BYTE_WORD: Field = 0x0100000000000000000000000000000000000000000000000000000000000000;
global L2_ASSET_ROUTER: Field = 0x10003;
global SELECTOR: [u8; 4] = [0x9c, 0x88, 0x4f, 0xd1]; // finalizeDeposit(uint256,bytes32,bytes)

// keccak256 constants as little-endian keccak lanes.
pub global BATCH_LEAF_PADDING: [u64; 4] = [0x47dccb374aec2fd8, 0xcfea4dd64acce5f1, 0x5bfa617c6f8ea434, 0xf49c2543e558fd68];
pub global CHAIN_ID_LEAF_PADDING: [u64; 4] = [0x6ce2b93b3669bc39, 0x9e56224ede4042f1, 0xde1acffb5c17cf95, 0x617fbfb453a2471a];
pub global RESERVED_SUBTREE_NODE: [u64; 4] = [0x8f6f7c955119c1b4, 0x46b2d61cf64a2c64, 0xee07c67fdcc6fe40, 0x300d41929ea90682];
pub global COMMIT_TAG_LANE: u64 = 0x000000004c134534; // bytes4(keccak256("AtomicInterop.commit.v1")), left-aligned
pub global NTV_WORD: [u64; 4] = [0, 0, 0, 0x0400010000000000]; // L2_NATIVE_TOKEN_VAULT_ADDR (0x10004) as a word

// ------------------------------------------------------------------------------------------ keccak

/// keccak256 of a message of 8 * NL bytes given as little-endian lanes.
pub fn keccak_lanes<let NL: u32>(msg: [u64; NL]) -> [u64; 4] {
    let blocks = (NL * 8) / 136 + 1;
    let mut st: [u64; 25] = [0; 25];
    for b in 0..blocks {
        for j in 0..17 {
            let idx = b * 17 + j;
            let mut lane: u64 = 0;
            if idx < NL {
                lane = msg[idx % NL];
            }
            if idx == NL {
                lane = lane ^ 0x01;
            }
            if idx == blocks * 17 - 1 {
                lane = lane ^ 0x8000000000000000;
            }
            if b == 0 {
                st[j] = lane;
            } else {
                st[j] = st[j] ^ lane;
            }
        }
        st = std::hash::keccakf1600(st);
    }
    [st[0], st[1], st[2], st[3]]
}

pub fn keccak_pair(a: [u64; 4], b: [u64; 4]) -> [u64; 4] {
    protocol_hash_lanes([a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]])
}

pub fn protocol_hash_lanes<let NL: u32>(_msg: [u64; NL]) -> [u64; 4] {
    keccak_lanes(_msg)
}

pub fn bytes_to_lanes<let L: u32, let NL: u32>(b: [u8; L]) -> [u64; NL] {
    std::static_assert(L == NL * 8, "length must be 8 * lanes");
    let mut out: [u64; NL] = [0; NL];
    for i in 0..NL {
        let mut acc: Field = 0;
        let mut mult: Field = 1;
        for k in 0..8 {
            acc += (b[i * 8 + k] as Field) * mult;
            mult *= 256;
        }
        out[i] = acc as u64;
    }
    out
}

pub fn lanes_to_bytes(l: [u64; 4]) -> [u8; 32] {
    let mut out: [u8; 32] = [0; 32];
    for i in 0..4 {
        let bytes: [u8; 8] = (l[i] as Field).to_le_bytes();
        for k in 0..8 {
            out[i * 8 + k] = bytes[k];
        }
    }
    out
}

/// The 32 bytes of `buf` at the compile-time offset `off`.
pub fn read_word<let L: u32>(buf: [u8; L], off: u32) -> [u8; 32] {
    let mut w: [u8; 32] = [0; 32];
    for i in 0..32 {
        w[i] = buf[off + i];
    }
    w
}

pub fn word_lanes<let L: u32>(buf: [u8; L], off: u32) -> [u64; 4] {
    bytes_to_lanes::<32, 4>(read_word(buf, off))
}

/// Big-endian word to a field element (reduced mod p).
pub fn word_to_field(w: [u8; 32]) -> Field {
    let mut acc: Field = 0;
    for i in 0..32 {
        acc = acc * 256 + (w[i] as Field);
    }
    acc
}

/// Big-endian 16-byte halves of a word.
pub fn hi_lo(w: [u8; 32]) -> (Field, Field) {
    let mut hi: Field = 0;
    let mut lo: Field = 0;
    for i in 0..16 {
        hi = hi * 256 + (w[i] as Field);
        lo = lo * 256 + (w[16 + i] as Field);
    }
    (hi, lo)
}

pub fn field_word_lanes(x: Field) -> [u64; 4] {
    bytes_to_lanes::<32, 4>(x.to_be_bytes::<32>())
}

/// Variable-height keccak Merkle path (FullMerkle / DynamicIncrementalMerkle shape). The cost is always D
/// levels; only the first `height` apply. Leaves of every tree used here have non-64-byte preimages.
pub fn merkle_var<let D: u32>(leaf: [u64; 4], index: Field, path: [[u64; 4]; D], height: u32) -> [u64; 4] {
    let bits: [bool; D] = index.to_le_bits();
    let mut node = leaf;
    for i in 0..D {
        let left = if bits[i] { path[i] } else { node };
        let right = if bits[i] { node } else { path[i] };
        let h = keccak_pair(left, right);
        if i < height {
            node = h;
        }
    }
    node
}

// --------------------------------------------------------------------------------------- Poseidon2

pub fn p2_hash2(a: Field, b: Field) -> Field {
    std::hash::poseidon2_permutation([a, b, 0, 2 * TWO_POW_64])[0]
}

pub fn p2_hash3(a: Field, b: Field, c: Field) -> Field {
    std::hash::poseidon2_permutation([a, b, c, 3 * TWO_POW_64])[0]
}

/// Rate-3 sponge with a length-tagged capacity element (std::hash::Poseidon2Hasher's layout).
pub fn p2_hash_many<let N: u32>(xs: [Field; N]) -> Field {
    let mut st: [Field; 4] = [0, 0, 0, (N as Field) * TWO_POW_64];
    for i in 0..(N / 3) {
        for j in 0..3 {
            st[j] += xs[3 * i + j];
        }
        st = std::hash::poseidon2_permutation(st);
    }
    for j in 0..(N % 3) {
        st[j] += xs[3 * (N / 3) + j];
    }
    std::hash::poseidon2_permutation(st)[0]
}

pub fn p2_merkle<let D: u32>(leaf: Field, index: Field, path: [Field; D]) -> Field {
    let bits: [bool; D] = index.to_le_bits();
    let mut node = leaf;
    for i in 0..D {
        let left = if bits[i] { path[i] } else { node };
        let right = if bits[i] { node } else { path[i] };
        node = p2_hash2(left, right);
    }
    node
}

// -------------------------------------------------------------------------------------------- state

/// ZKIP's private per-chain state: the interop balance P per asset, and the consumed commit values.
pub struct State {
    pub bal_asset: [Field; MAX_ASSETS],
    pub bal_amount: [Field; MAX_ASSETS],
    pub null_root: Field,
    pub null_size: Field,
}

pub fn state_root(s: State) -> Field {
    let mut xs: [Field; 19] = [0; 19];
    xs[0] = STATE_VERSION;
    for i in 0..MAX_ASSETS {
        xs[1 + i] = s.bal_asset[i];
        xs[9 + i] = s.bal_amount[i];
    }
    xs[17] = s.null_root;
    xs[18] = s.null_size;
    p2_hash_many(xs)
}

/// Adds `amount` to (credit) or subtracts it from (debit) asset `asset` in the witness-chosen slot.
/// A debit below zero wraps past 2^128 and fails the range check.
pub fn apply_delta(s: &mut State, slot: u32, asset: Field, amount: Field, credit: bool) {
    assert(asset != 0, "asset key zero");
    let current = s.bal_asset[slot];
    if current != asset {
        assert(current == 0, "slot holds another asset");
        for j in 0..MAX_ASSETS {
            assert(s.bal_asset[j] != asset, "asset already in another slot");
        }
        s.bal_asset[slot] = asset;
    }
    let old = s.bal_amount[slot];
    let new = if credit { old + amount } else { old - amount };
    new.assert_max_bit_size::<128>();
    s.bal_amount[slot] = new;
}

/// Inserts `key` into the consumed set, an append-only Poseidon2 indexed Merkle tree (empty leaf = 0).
pub fn null_insert(
    s: &mut State,
    key: Field,
    low: [Field; 3],
    low_index: Field,
    low_path: [Field; NULL_DEPTH],
    new_path: [Field; NULL_DEPTH],
) {
    assert(key != 0, "zero key");
    assert(low[0].lt(key), "low leaf not below key");
    assert((low[2] == 0) | key.lt(low[2]), "key already consumed or bad low leaf");
    let r0 = p2_merkle(p2_hash3(low[0], low[1], low[2]), low_index, low_path);
    assert(r0 == s.null_root, "low leaf not in consumed set");
    let r1 = p2_merkle(p2_hash3(low[0], s.null_size, key), low_index, low_path);
    let empty = p2_merkle(0, s.null_size, new_path);
    assert(empty == r1, "append slot not empty");
    s.null_root = p2_merkle(p2_hash3(key, low[1], low[2]), s.null_size, new_path);
    s.null_size += 1;
}

// ------------------------------------------------------------------------------- bundles and flows

fn assert_word<let L: u32>(buf: [u8; L], off: u32, value: Field) {
    assert(word_to_field(read_word(buf, off)) == value, "template mismatch");
}

/// The single-indirect-call ERC20 leg template (InteropCenter._buildInteropBundle with
/// L2AssetRouter.initiateIndirectCall, token name and symbol up to 32 bytes, empty executionAddress).
/// Fixing every offset and length makes the field reads below the same ones abi.decode performs.
fn check_bundle_template(b: [u8; BUNDLE_LEN]) {
    assert_word(b, 0x00, 0x20);
    assert_word(b, 0x20, VERSION_BYTE_WORD);
    assert_word(b, 0xc0, 0xe0);
    assert_word(b, 0xe0, 0x540);
    assert_word(b, 0x100, 1);
    assert_word(b, 0x120, 0x20);
    assert_word(b, 0x140, VERSION_BYTE_WORD);
    assert_word(b, 0x160, 0);
    assert_word(b, 0x180, L2_ASSET_ROUTER);
    assert_word(b, 0x1a0, L2_ASSET_ROUTER);
    assert_word(b, 0x1c0, 0);
    assert_word(b, 0x1e0, 0xc0);
    assert_word(b, 0x200, 804);
    for i in 0..4 {
        assert(b[0x220 + i] == SELECTOR[i], "not finalizeDeposit");
    }
    assert_word(b, 0x264, 0x60);
    assert_word(b, 0x284, 672);
    assert_word(b, 0x324, 0xa0);
    assert_word(b, 0x344, 449);
    assert(b[0x364] == 1, "metadata encoding version");
    assert_word(b, 0x560, 0x80);
    assert_word(b, 0x580, 0xa0);
    assert_word(b, 0x5e0, 0);
}

/// abi.encode(AtomicFlowPreimage) with exactly two legs.
fn check_preimage_template(p: [u8; PRE_LEN], l1_chain_id: Field) {
    assert_word(p, 0x00, 0x20);
    assert_word(p, 0x20, VERSION_BYTE_WORD);
    word_to_field(read_word(p, 0x40)).assert_max_bit_size::<64>();
    assert_word(p, 0x60, l1_chain_id);
    assert_word(p, 0x80, 0xa0);
    assert_word(p, 0xa0, 0x100);
    assert_word(p, 0xc0, 2);
    assert_word(p, 0x120, 2);
}

pub fn commit_value(flow_id: [u64; 4], bundle_hash: [u64; 4]) -> [u64; 4] {
    keccak_lanes(
        [
            COMMIT_TAG_LANE, 0, 0, 0, flow_id[0], flow_id[1], flow_id[2], flow_id[3], bundle_hash[0],
            bundle_hash[1], bundle_hash[2], bundle_hash[3],
        ],
    )
}

pub struct Opened {
    pub cv: [[u64; 4]; 2],
    pub leg_src: [Field; 2],
    pub deadline: u64,
    pub src: Field,
    pub dst: Field,
    pub asset_key: Field,
    pub amount: Field,
    pub origin_chain: Field,
}

/// Opens one leg: binds the bundle to the flow preimage at slot `leg`, recomputes flowId and both commit
/// values, and decodes the asset-router call.
pub fn open_leg(bundle: [u8; BUNDLE_LEN], pre: [u8; PRE_LEN], leg: bool, l1_chain_id: Field) -> Opened {
    check_bundle_template(bundle);
    check_preimage_template(pre, l1_chain_id);
    let bh = keccak_lanes(bytes_to_lanes::<BUNDLE_LEN, 200>(bundle));
    let h0 = word_lanes(pre, 0xe0);
    let h1 = word_lanes(pre, 0x100);
    let own = if leg { h1 } else { h0 };
    assert(own == bh, "bundle is not this leg of the flow");
    let c0 = word_to_field(read_word(pre, 0x140));
    let c1 = word_to_field(read_word(pre, 0x160));
    let src = word_to_field(read_word(bundle, 0x40));
    assert(src == (if leg { c1 } else { c0 }), "bundle source differs from the leg source");
    assert(word_to_field(read_word(bundle, 0x224)) == src, "finalizeDeposit source chain");
    let flow_id = keccak_lanes(bytes_to_lanes::<PRE_LEN, 48>(pre));

    let origin_chain_lanes = word_lanes(bundle, 0x365);
    let token_lanes = word_lanes(bundle, 0x2e4);
    let asset_id = keccak_lanes(
        [
            origin_chain_lanes[0], origin_chain_lanes[1], origin_chain_lanes[2], origin_chain_lanes[3],
            NTV_WORD[0], NTV_WORD[1], NTV_WORD[2], NTV_WORD[3], token_lanes[0], token_lanes[1], token_lanes[2],
            token_lanes[3],
        ],
    );
    assert(asset_id == word_lanes(bundle, 0x244), "asset id is not the NTV id of the origin token");
    let amount = word_to_field(read_word(bundle, 0x304));
    amount.assert_max_bit_size::<128>();

    Opened {
        cv: [commit_value(flow_id, h0), commit_value(flow_id, h1)],
        leg_src: [c0, c1],
        deadline: word_to_field(read_word(pre, 0x40)) as u64,
        src,
        dst: word_to_field(read_word(bundle, 0x60)),
        asset_key: word_to_field(read_word(bundle, 0x244)),
        amount,
        origin_chain: word_to_field(read_word(bundle, 0x365)),
    }
}

pub fn cv_key(cv: [u64; 4]) -> Field {
    word_to_field(lanes_to_bytes(cv))
}

// -------------------------------------------------------------------------------------- finality

/// Root of L1's shared message tree implied by one leg's inclusion: commit value in the source IMT
/// (batch-END root, chain batch root leaf 3), batch leaf with its settlement timestamp, chain tree,
/// chain-id leaf, shared tree (MessageHashing._getProofData, both hops, unrolled).
pub fn shared_root(
    cv: [u64; 4],
    source_chain: Field,
    imt_next_index: [u64; 4],
    imt_next_value: [u64; 4],
    imt_index: Field,
    imt_height: u32,
    imt_path: [[u64; 4]; D_IMT],
    cbr_begin: [u64; 4],
    cbr_left: [u64; 4],
    batch_number: Field,
    batch_ts: u64,
    chain_height: u32,
    chain_path: [[u64; 4]; D_CHAIN],
    shared_index: Field,
    shared_height: u32,
    shared_path: [[u64; 4]; D_SHARED],
) -> [u64; 4] {
    let leaf = keccak_lanes(
        [
            cv[0], cv[1], cv[2], cv[3], imt_next_index[0], imt_next_index[1], imt_next_index[2],
            imt_next_index[3], imt_next_value[0], imt_next_value[1], imt_next_value[2], imt_next_value[3],
        ],
    );
    let imt_root = merkle_var(leaf, imt_index, imt_path, imt_height);
    let live = keccak_pair(cbr_left, keccak_pair(cbr_begin, imt_root));
    let batch_root = keccak_pair(live, RESERVED_SUBTREE_NODE);
    let bn = field_word_lanes(batch_number);
    let ts = field_word_lanes(batch_ts as Field);
    let batch_leaf = keccak_lanes(
        [
            BATCH_LEAF_PADDING[0], BATCH_LEAF_PADDING[1], BATCH_LEAF_PADDING[2], BATCH_LEAF_PADDING[3],
            batch_root[0], batch_root[1], batch_root[2], batch_root[3], bn[0], bn[1], bn[2], bn[3], ts[0], ts[1],
            ts[2], ts[3],
        ],
    );
    let chain_root = merkle_var(batch_leaf, batch_number, chain_path, chain_height);
    let cid = field_word_lanes(source_chain);
    let chain_leaf = keccak_lanes(
        [
            CHAIN_ID_LEAF_PADDING[0], CHAIN_ID_LEAF_PADDING[1], CHAIN_ID_LEAF_PADDING[2],
            CHAIN_ID_LEAF_PADDING[3], chain_root[0], chain_root[1], chain_root[2], chain_root[3], cid[0], cid[1],
            cid[2], cid[3],
        ],
    );
    merkle_var(chain_leaf, shared_index, shared_path, shared_height)
}
