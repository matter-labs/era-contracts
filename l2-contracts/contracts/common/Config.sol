// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

uint256 constant L1_CHAIN_ID = 9;
address constant ETH_TOKEN_ADDRESS = address(1);
address constant NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS = address(2);
bytes32 constant TWO_BRIDGES_MAGIC_VALUE = bytes32(uint256(keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1);
