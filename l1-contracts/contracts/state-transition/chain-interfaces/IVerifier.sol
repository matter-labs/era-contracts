// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @notice Part of the configuration parameters of ZKP circuits
struct VerifierParams {
    bytes32 recursionNodeLevelVkHash;
    bytes32 recursionLeafLevelVkHash;
    bytes32 recursionCircuitsSetVksHash;
}

/// @notice A struct that represents an elliptic curve point.
struct ECPoint {
    uint256 x;
    uint256 y;
}

/// @notice A struct that represents the verification key data.
struct VerificationKeyData {
    ECPoint[8] gateSetup; // 8 elements for gate setups
    ECPoint[2] gateSelectors; // 2 elements for gate selectors
    ECPoint[4] permutation; // 4 elements for permutations
    ECPoint lookupSelector; // Single element for lookup selector
    ECPoint[4] lookupTable; // 4 elements for lookup tables
    ECPoint lookupTableType; // Single element for lookup table type
    uint256 recursiveFlag; // Single element for recursive flag
}

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

    /// @notice Returns the "packed" verification key. This `bytes` array contains all the elements
    /// of the VK, however they are not properly ABI-encoded.
    function verificationKey() external pure returns (VerificationKeyData memory);
}
