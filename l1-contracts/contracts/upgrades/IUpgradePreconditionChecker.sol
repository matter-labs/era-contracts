// SPDX-License-Identifier: MIT

// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev The magic value that has to be returned by `getSupportsUpgradePreconditionCheckerMagic`.
bytes32 constant UPGRADE_PRECONDITION_CHECKER_MAGIC = keccak256("UpgradePreconditionChecker");

/// @title Upgrade precondition checker interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Release-specific checks that must hold for a chain before its upgrade may be scheduled
/// through `ServerNotifier.setUpgradeTimestamp`; see {protocol-docs/upgrade-scheduling.md}.
interface IUpgradePreconditionChecker {
    /// @notice A method used to check that the contract supports this interface.
    /// @return Returns the `UPGRADE_PRECONDITION_CHECKER_MAGIC`.
    function getSupportsUpgradePreconditionCheckerMagic() external view returns (bytes32);

    /// @notice Ensures the chain can take the upgrade this checker guards; reverts with a
    /// precondition-specific error otherwise.
    /// @param _chainId The id of the chain whose upgrade is being scheduled.
    /// @param _zkChain The chain's DiamondProxy address.
    function checkUpgradePreconditions(uint256 _chainId, address _zkChain) external view;

    /// @notice Non-reverting mirror of `checkUpgradePreconditions`.
    /// @param _chainId The id of the chain whose upgrade is being scheduled.
    /// @param _zkChain The chain's DiamondProxy address.
    /// @return failed The error selectors of every failed precondition; empty when the check passes.
    function previewUpgradePreconditions(
        uint256 _chainId,
        address _zkChain
    ) external view returns (bytes4[] memory failed);
}
