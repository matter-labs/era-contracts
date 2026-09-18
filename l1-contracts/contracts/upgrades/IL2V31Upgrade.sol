// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2V31Upgrade {
    /// @notice Executes the one-time v31 upgrade on L2.
    /// @dev Intended to be delegate-called by the `ComplexUpgrader` contract.
    /// @param _isZKsyncOS Whether this is a ZKsync OS chain.
    /// @param _ctmDeployer The address of the CTM deployer.
    /// @param _fixedForceDeploymentsData Encoded FixedForceDeploymentsData (same for all chains).
    /// @param _additionalForceDeploymentsData Encoded ZKChainSpecificForceDeploymentsData (per-chain).
    function upgrade(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external;
}
