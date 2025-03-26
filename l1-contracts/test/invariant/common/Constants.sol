// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

uint256 constant AMOUNT_UPPER_BOUND = 1e12 * 1e18;
// borrowed from https://github.com/matter-labs/era-contracts/blob/16dedf6d77695ce00f81fce35a3066381b97fca1/l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol#L64-L68
address constant L1_TOKEN_ADDRESS = 0x1111100000000000000000000000000000011111;
string constant TOKEN_DEFAULT_NAME = "TestnetERC20Token";
string constant TOKEN_DEFAULT_SYMBOL = "TET";
uint8 constant TOKEN_DEFAULT_DECIMALS = 18;
