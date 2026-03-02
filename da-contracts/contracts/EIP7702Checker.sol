// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.28;

/// @title EIP7702Checker
/// @notice Utility to detect EIP-7702 account
/// @dev See: https://eips.ethereum.org/EIPS/eip-7702
contract EIP7702Checker {
    uint256 internal constant EIP7702_CODE_SIZE = 23;
    bytes3 internal constant EIP7702_PREFIX = 0xef0100;

    function isEIP7702Account(address _account) external view returns (bool) {
        if (_account.code.length != EIP7702_CODE_SIZE) return false;

        bytes3 prefix;
        assembly {
            let ptr := mload(0x40) // load free memory pointer
            extcodecopy(_account, ptr, 0, 3)
            prefix := mload(ptr) // read back into stack
        }

        return prefix == EIP7702_PREFIX;
    }
}
