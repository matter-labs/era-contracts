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
bytes32 constant BATCH_OUTPUT_HASH_GOLDEN = 0x1c24f398aa0701f9348912ecca748ba93bfb84bfe4f283c16514311419f4f658;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN = 0x115e07747f99e4785e3f1c91d3ff85f05eee22c99004e6a81adc37b1b21495fe;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY = 0x7bb4bea265b944d45623d3e57de083aceb9c7d9f30240c3a917fa187a4444282;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY = 0xac58d82a0990197b31c12ec9cc33b330e5dbda74011eafd37b7e78a5241f0ec7;
bytes32 constant PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS = 0xa78ab15446de058e9f871114c4b0333d8ab23ec8959f89b582c33409751aa837;
