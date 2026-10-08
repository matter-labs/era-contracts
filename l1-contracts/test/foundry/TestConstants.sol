// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

string constant NEW_PRIORITY_REQUEST_SIGNATURE = "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])";
address constant RAND_ADDRESS = address(0xDEAD);
uint256 constant LEGACY_PRIORITY_TX_MAX_GAS_LIMIT = 72_000_000;
uint256 constant TEST_PRIORITY_TX_L2_GAS_LIMIT = 1_000_000;
uint256 constant TEST_PRIORITY_TX_L1_GAS_PRICE = 10_000_000;

uint32 constant TEST_CHAIN_CONFIG_UPGRADE_VERSION = 34;
uint256 constant TEST_CHAIN_ID = 9;
uint8 constant LEGACY_V33_COMMIT_ENCODING_VERSION = 4;
string constant LEGACY_V33_COMMITMENT_FACETS_PATH = "test/foundry/l1/integration/fixtures/v33-commitment-facets.json";

// Shared with ZKsync OS public_input.rs golden-vector tests; see {protocol-docs/chain-config.md}.
uint256 constant GOLDEN_CHAIN_ID = 37;
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN = 0x3fa2b6bcbfde24e4aa05b9d48bb04bd3f183713bdd31889f976c74ff7694c1ab;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN = 0x080b613ec5a9df68d47b8008f89e814a87d2b13fc3a3fa5752c44677ad58b8a3;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY = 0xa078b769783cbdc3cb68c5f68bd3e330668d78f369bf95c1f6b019e3aaf41b50;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY = 0x500121afefb9942d2cbc7b7b689bbcc4054777c8eccc4a46eeb1d9a3626a6b78;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS = 0x5364213bf06d28ee488265c45060455d09ad9d76bfbb329c8dfb9befccf19512;
// Batch output hashes of `_goldenInteropFeeBatch(7)` / `(0)` in ZKsyncOSPublicInput.t.sol, shared with ZKsync OS
// public_input.rs `batch_output_hash_commits_to_interop_fee_units_last`; see {protocol-docs/interop-fee.md}.
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_7 = 0x82cf2f4e531d92c0cf48eb93b02a24791907cbfe3b92362df3519e8a0c62fb7b;
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_0 = 0xafe723d2b10a24d8e3c16572229996f1b43e2d9d9fbb5a6b3a0b32b1c8408be1;
