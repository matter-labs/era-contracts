// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @notice Interface for the AccountCodeStorage system contract.
interface IAccountCodeStorage {
    function getRawCodeHash(address _address) external view returns (bytes32 codeHash);
}
