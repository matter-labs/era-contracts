// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title IEIP7702Checker
/// @notice Interface for checking if an address is an EIP-7702 style account (EOA with code stub).
/// @dev See: https://eips.ethereum.org/EIPS/eip-7702
interface IEIP7702Checker {
    /**
     * @notice Returns true if the given account has exactly the EIP-7702 code stub.
     * @param account The address to check.
     * @return isStub True if the account matches the EIP-7702 code pattern.
     */
    function isEIP7702Account(address account) external view returns (bool isStub);
}
