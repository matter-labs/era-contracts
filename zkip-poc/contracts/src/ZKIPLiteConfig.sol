// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

uint256 constant DEBIT_1_CIRCUIT_ID = 1001;
uint256 constant AGGREGATED_DIGEST_INPUTS = 2;
uint256 constant ZKIP_STATEMENT_INPUTS = 16;
uint256 constant AGGREGATED_SMALL_SLOTS = 4;
uint256 constant AGGREGATED_LARGE_SLOTS = 16;
uint256 constant AGGREGATED_CHILD_KEY_INPUTS = 1;
uint256 constant RECURSIVE_AGGREGATION_INPUTS = 6;
uint256 constant RECURSIVE_AGGREGATION_MAX_HEIGHT = 30;
uint256 constant DIGEST_LIMB_BITS = 128;
uint8 constant AGGREGATION_FOLD_TOKEN = 128;
bytes32 constant AGGREGATION_BASE_DOMAIN = keccak256("zkSync:ZKIP:aggregationBase:v1");
bytes32 constant AGGREGATION_FOLD_DOMAIN = keccak256("zkSync:ZKIP:aggregationFold:v1");
bytes32 constant AGGREGATED_STATEMENT_DOMAIN = keccak256("zkSync:ZKIP:aggregatedStatement:v1");
