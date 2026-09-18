// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

string constant NEW_PRIORITY_REQUEST_SIGNATURE = "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])";
address constant RAND_ADDRESS = address(0xDEAD);

/// @dev `forceFailedL1TxLogKey()` in the bootloader, where `TEST_systemLogKeys` pins it against this
///      preimage. Test-only: no L1 contract reads the key, they only prove the logs carrying it.
bytes32 constant FORCE_FAILED_L1_TX_LOG_KEY = keccak256("zksync.bootloader.forceFailedL1TxLog");
