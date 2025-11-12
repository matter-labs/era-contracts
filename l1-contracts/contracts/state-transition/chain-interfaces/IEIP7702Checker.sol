// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title IEIP7702Checker
/// @notice Interface for checking if an address is an EIP-7702 style account.
/// @dev See: https://eips.ethereum.org/EIPS/eip-7702
interface IEIP7702Checker {
    /**
     * @notice Returns true if the given account corresponds to EIP-7702.
     * @param account The address to check.
     * @return isEIP7702 True if the account matches the EIP-7702 code pattern.
     */
    function isEIP7702Account(address account) external view returns (bool isEIP7702);
}
