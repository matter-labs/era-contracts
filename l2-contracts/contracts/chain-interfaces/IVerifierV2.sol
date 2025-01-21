// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title The interface of the Verifier contract, responsible for the zero knowledge proof verification.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IVerifierV2 {
    /// @dev Verifies a zk-SNARK proof.
    /// @return A boolean value indicating whether the zk-SNARK proof is valid.
    /// Note: The function may revert execution instead of returning false in some cases.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external view returns (bool);

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys.
    /// @return vkHash The keccak256 hash of the loaded verification keys.
    function verificationKeyHash() external view returns (bytes32);
}
