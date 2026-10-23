// Experimental transfer encoding; see benchmarks/README.md. The origin preimage remains authenticated:
// treating an unverified origin chain as a hint would let a debit bypass balance accounting.
pub fn open_leg(_bundle: [u8; BUNDLE_LEN], _pre: [u8; PRE_LEN], _leg: bool, _l1_chain_id: Field) -> Opened {
    assert(read_word(_bundle, 0) == VERSION_BYTE_WORD.to_be_bytes::<32>(), "transfer version");
    check_preimage_template(_pre, _l1_chain_id);
    let bh = protocol_hash_lanes(bytes_to_lanes::<BUNDLE_LEN, BUNDLE_LANES>(_bundle));
    let h0 = word_lanes(_pre, 0xe0);
    let h1 = word_lanes(_pre, 0x100);
    assert((if _leg { h1 } else { h0 }) == bh, "bundle is not this leg of the flow");
    let c0 = word_to_field(read_word(_pre, 0x140));
    let c1 = word_to_field(read_word(_pre, 0x160));
    let src = compact_uint::<64>(_bundle, 32);
    assert(src == (if _leg { c1 } else { c0 }), "bundle source differs from the leg source");
    let dst = compact_uint::<64>(_bundle, 64);
    let amount = compact_uint::<128>(_bundle, 128);
    let origin = compact_uint::<64>(_bundle, 160);
    let _token = compact_uint::<160>(_bundle, 192);
    let _sender = compact_uint::<160>(_bundle, 224);
    let _recipient = compact_uint::<160>(_bundle, 256);
    let ow = word_lanes(_bundle, 160);
    let tw = word_lanes(_bundle, 192);
    // Asset IDs stay the protocol's Keccak NTV IDs, even in the BLAKE/Poseidon experiments.
    let asset_id = keccak_lanes([
        ow[0], ow[1], ow[2], ow[3], NTV_WORD[0], NTV_WORD[1], NTV_WORD[2], NTV_WORD[3],
        tw[0], tw[1], tw[2], tw[3],
    ]);
    assert(asset_id == word_lanes(_bundle, 96), "asset id is not the NTV id of the origin token");
    let flow_id = protocol_hash_lanes(bytes_to_lanes::<PRE_LEN, 48>(_pre));
    Opened {
        cv: [commit_value(flow_id, h0), commit_value(flow_id, h1)],
        leg_src: [c0, c1],
        deadline: word_to_field(read_word(_pre, 0x40)) as u64,
        src,
        dst,
        asset_key: word_to_field(read_word(_bundle, 96)),
        amount,
        origin_chain: origin,
    }
}

fn compact_uint<let BITS: u32>(_bundle: [u8; BUNDLE_LEN], _offset: u32) -> Field {
    let bytes = read_word(_bundle, _offset);
    let value = word_to_field(bytes);
    assert(bytes == value.to_be_bytes::<32>(), "noncanonical transfer integer");
    value.assert_max_bit_size::<BITS>();
    value
}
