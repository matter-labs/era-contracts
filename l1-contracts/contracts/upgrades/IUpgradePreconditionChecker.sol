// SPDX-License-Identifier: MIT

// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Upgrade precondition checker interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Release-specific upgrade scheduling checks; see {protocol-docs/upgrade-scheduling.md}.
interface IUpgradePreconditionChecker {
    /// @notice Confirms support for this interface.
    /// @return The canonical upgrade-precondition checker magic value.
    function getSupportsUpgradePreconditionCheckerMagic() external view returns (bytes32);

    /// @notice Reverts if the chain cannot take the guarded upgrade.
    /// @param _chainId The id of the chain whose upgrade is being scheduled.
    /// @param _zkChain The chain's DiamondProxy address.
    function checkUpgradePreconditions(uint256 _chainId, address _zkChain) external view;

    /// @notice Reports failed precondition predicates without reverting for those failures.
    /// @dev Calls to external dependencies may still revert.
    /// @param _chainId The id of the chain whose upgrade is being scheduled.
    /// @param _zkChain The chain's DiamondProxy address.
    /// @return failed The error selectors of the failed preconditions; empty when the check passes.
    function previewUpgradePreconditions(
        uint256 _chainId,
        address _zkChain
    ) external view returns (bytes4[] memory failed);
}
