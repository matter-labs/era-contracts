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
            // Advance the free memory pointer even though this function doesn't allocate more
            // memory afterwards. Project convention: every assembly block that
            // writes to memory at `mload(0x40)` must keep the free memory pointer in a consistent
            // state so future refactors (e.g. adding logic after this block or making the function
            // `internal`) don't silently corrupt adjacent memory.
            mstore(0x40, add(ptr, 0x20))
        }

        return prefix == EIP7702_PREFIX;
    }
}
