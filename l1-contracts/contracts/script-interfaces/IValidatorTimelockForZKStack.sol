// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IValidatorTimelockForZKStack
/// @notice Interface for Validator Timelock specifically for zkStack CLI usage
/// @dev This interface includes methods that may be legacy or specific to zkStack CLI needs
interface IValidatorTimelockForZKStack {
    /// @notice Role hash for addresses allowed to precommit batches on a chain.
    function PRECOMMITTER_ROLE() external view returns (bytes32);

    /// @notice Role hash for addresses allowed to commit batches on a chain.
    function COMMITTER_ROLE() external view returns (bytes32);

    /// @notice Role hash for addresses allowed to prove batches on a chain.
    function PROVER_ROLE() external view returns (bytes32);

    /// @notice Role hash for addresses allowed to execute batches on a chain.
    function EXECUTOR_ROLE() external view returns (bytes32);

    /// @notice Check if an address has a specific role for a chain
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _role The bytes32 ID of the role.
    /// @param _account The address to check.
    function hasRole(uint256 _chainId, bytes32 _role, address _account) external view returns (bool);

    /// @notice Check if an address has a specific role for a chain
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _role The bytes32 ID of the role.
    /// @param _account The address to check.
    function hasRoleForChainId(uint256 _chainId, bytes32 _role, address _account) external view returns (bool);

    /// @notice Legacy function from pre-v29 for backward compatibility
    /// @dev This function is deprecated but kept for backward compatibility with older zkStack CLI versions
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _validator The address of the validator to check.
    /// @return Whether the validator has any roles for the chain.
    function validators(uint256 _chainId, address _validator) external view returns (bool);
}
