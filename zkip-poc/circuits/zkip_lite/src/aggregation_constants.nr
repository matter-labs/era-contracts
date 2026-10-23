pub global AGG_SLOTS: u32 = 4;
pub global AGG_SLOT_INPUTS: u32 = 16;
pub global AGG_DIGEST_INPUTS: u32 = 2;
// keccak256("zkSync:ZKIP:aggregatedStatement:v1"), as little-endian lanes.
pub global STATEMENT_DOMAIN: [u64; 4] = [
    0x09835240548aa623, 0x618ff89222ffcba0, 0xc6c75e93c58f4a3f, 0x5ae38ab54c7639e2,
];
