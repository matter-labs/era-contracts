// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

string constant NEW_PRIORITY_REQUEST_SIGNATURE = "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])";
address constant RAND_ADDRESS = address(0xDEAD);
uint256 constant TEST_PRIORITY_TX_L2_GAS_LIMIT = 1_000_000;
uint256 constant TEST_PRIORITY_TX_L1_GAS_PRICE = 10_000_000;

uint32 constant TEST_CHAIN_CONFIG_UPGRADE_VERSION = 34;
uint256 constant TEST_CHAIN_ID = 9;
uint8 constant LEGACY_V33_COMMIT_ENCODING_VERSION = 4;
string constant LEGACY_V33_COMMITMENT_FACETS_PATH = "test/foundry/l1/integration/fixtures/v33-commitment-facets.json";
