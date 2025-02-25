// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title SloadContract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract provides a method to read values from arbitrary storage slots
/// @dev It is used by the `SystemContractHelper` library to help system contracts read
/// arbitrary slots of contracts.
contract SloadContract {
    /// @notice Reads the value stored at a specific storage slot
    /// @param slot The storage slot number to read from
    /// @return value The value stored at the specified slot as a bytes32 type
    function sload(bytes32 slot) external view returns (bytes32 value) {
        assembly {
            // sload retrieves the value at the given storage slot
            value := sload(slot)
        }
    }
}
