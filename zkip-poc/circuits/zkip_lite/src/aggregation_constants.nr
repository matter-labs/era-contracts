pub global AGG_SLOTS: u32 = 4;
pub global AGG_SLOT_INPUTS: u32 = 16;
pub global AGG_DIGEST_INPUTS: u32 = 2;
pub global AGG_LARGE_SLOTS: u32 = AGG_SLOTS * AGG_SLOTS;
pub global AGG_VK_LEN: u32 = 115;
pub global AGG_PROOF_LEN: u32 = 458; // RECURSIVE_ZK_PROOF_LENGTH in bb v5.2.1
pub global AGG_PROOF_TYPE_HONK_ZK: u32 = 6;
pub global RECURSIVE_NODE_INPUTS: u32 = 6;
pub global RECURSIVE_MAX_HEIGHT: u32 = 30;
pub global AGGREGATION_BASE_DOMAIN: [u64; 4] = [0x538d116683b54276, 0xd8f7340ce7d1bc2f, 0xcefe3ddb71ae8c63, 0x2b71c6fbbfb6cea5];
pub global AGGREGATION_FOLD_DOMAIN: [u64; 4] = [0x1f853ed34b0f1fe3, 0xfccbce354a33bffb, 0x8b3af4c9e6897090, 0x165547dbad244d4a];
// keccak256("zkSync:ZKIP:aggregatedStatement:v1"), as little-endian lanes.
pub global STATEMENT_DOMAIN: [u64; 4] = [
    0x09835240548aa623, 0x618ff89222ffcba0, 0xc6c75e93c58f4a3f, 0x5ae38ab54c7639e2,
];
