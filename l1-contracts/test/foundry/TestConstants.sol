// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

string constant NEW_PRIORITY_REQUEST_SIGNATURE = "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])";
address constant RAND_ADDRESS = address(0xDEAD);
uint256 constant LEGACY_PRIORITY_TX_MAX_GAS_LIMIT = 72_000_000;
uint256 constant TEST_PRIORITY_TX_L2_GAS_LIMIT = 1_000_000;
uint256 constant TEST_PRIORITY_TX_L1_GAS_PRICE = 10_000_000;

uint32 constant TEST_CHAIN_CONFIG_UPGRADE_VERSION = 34;
uint256 constant TEST_CHAIN_ID = 9;

// Shared with ZKsync OS public_input.rs golden-vector tests; see {protocol-docs/chain-config.md}.
uint256 constant GOLDEN_CHAIN_ID = 37;
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN = 0x3fa2b6bcbfde24e4aa05b9d48bb04bd3f183713bdd31889f976c74ff7694c1ab;
// Since v36 the chain config hash has seven words (`l1sload_enabled` is the seventh).
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN = 0x19c9f44479b3849265ebc58630ad42452ce077aa081af2c5a6ca9e2bb288288c;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY = 0x8bfa5df0c8871c96fff5322b35d14553bcf4917b8cfef1e4d02e41ba3e6e508d;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY = 0xeec156b2928698ac0946c50216c8c745c5b4a2cb24b992688336d491a3024fbd;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS = 0x52217554538e20800b58fce27525e2abd540af67864fc13fe72bdc6a1f0e3cf7;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_L1SLOAD_ONLY = 0x1321e994bbfec787b02d5435de7811d5a3a5e2367af6770a4741f326fc54551d;
// Batch output hashes of `_goldenInteropFeeBatch(7)` / `(0)` in ZKsyncOSPublicInput.t.sol, shared with ZKsync OS
// public_input.rs `batch_output_hash_commits_to_interop_fee_units_last`; see {protocol-docs/interop-fee.md}.
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_7 = 0x82cf2f4e531d92c0cf48eb93b02a24791907cbfe3b92362df3519e8a0c62fb7b;
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_0 = 0xafe723d2b10a24d8e3c16572229996f1b43e2d9d9fbb5a6b3a0b32b1c8408be1;

// The anvil-interop fixture ecosystems (`test/anvil-interop/chain-states/`): their L1 chain id and the default anvil
// account that deployed them and still owns them, operates their chains and admins them.
uint256 constant ANVIL_FIXTURE_L1_CHAIN_ID = 31337;
address constant ANVIL_FIXTURE_DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
// Commit encoding 5 is the one releases before v0.35 decode; v0.35 moved to 6 (`BatchDecoder`).
uint8 constant BATCH_COMMIT_ENCODING_V5 = 5;
uint32 constant BATCH_COMMIT_ENCODING_V6_FIRST_MINOR = 35;
