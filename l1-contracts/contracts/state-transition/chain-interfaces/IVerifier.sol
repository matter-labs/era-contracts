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
    /// @notice 8 points for gate setups
    ECPoint[8] gateSetup;
    /// @notice 2 points for gate selectors
    ECPoint[2] gateSelectors;
    /// @notice 4 points for permutations
    ECPoint[4] permutation;
    /// @notice A point element for lookup selector
    ECPoint lookupSelector;
    /// @notice 4 points for lookup tables
    ECPoint[4] lookupTable;
    /// @notice A point for lookup table type
    ECPoint lookupTableType;
    /// @notice A flag that denotes whether recursion is supported
    uint256 recursiveFlag;
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

    /// @notice Returns the verification key.
    /// @dev IMPORTANT: The outside developers should not expect this method to always return result in the same
    /// format. It might be changed in case of the change of the verification key format.
    function verificationKey() external pure returns (VerificationKeyData memory);
}
