// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2DefaultUpgrade {
    /// @notice Executes the L2 side of a regular protocol upgrade.
    /// @dev Intended to be delegate-called by the `ComplexUpgrader` contract.
    /// @param _ctmDeployer The address of the CTM deployer.
    /// @param _fixedForceDeploymentsData Encoded FixedForceDeploymentsData (same for all chains).
    /// @param _additionalForceDeploymentsData Encoded ZKChainSpecificForceDeploymentsData (per-chain).
    function upgrade(
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external;
}
