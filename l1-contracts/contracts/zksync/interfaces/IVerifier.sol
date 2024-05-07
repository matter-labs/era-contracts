// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title The interface of the Verifier contract, responsible for the zero knowledge proof verification.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IVerifier {
    /// @dev Verifies a zk-SNARK proof.
    /// @return A boolean value indicating whether the zk-SNARK proof is valid.
    /// Note: The function may revert execution instead of returning false in some cases.
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof,
        uint256[] calldata _recursiveAggregationInput
    ) external view returns (bool);

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys.
    /// @return vkHash The keccak256 hash of the loaded verification keys.
    function verificationKeyHash() external pure returns (bytes32);
}
