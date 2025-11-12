// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.28;

/// @title EIP7702Checker
/// @notice Utility to detect EIP-7702 account
/// @dev See: https://eips.ethereum.org/EIPS/eip-7702
contract MockEIP7702Checker {
    function isEIP7702Account(address _account) external view returns (bool) {
        // EIP7702 is not enabled on ZK chains, false can always be safely returned
        return false;
    }
}
