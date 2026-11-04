// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Config, CoreDeployedAddresses} from "../deploy-scripts/ecosystem/DeployL1CoreUtils.s.sol";

/// @title IDeployL1CoreContracts
/// @notice Interface for the L1 Core Contracts deployment script
interface IDeployL1CoreContracts {
    /// @notice Runs the deployment with default paths
    function run() external;

    /// @notice Runs the deployment for testing purposes
    /// @dev Accepts admin role after deployment for testing
    function runForTest() external;

    /// @notice Returns the deployed contract addresses
    /// @return The CoreDeployedAddresses struct containing all deployed addresses
    function getAddresses() external view returns (CoreDeployedAddresses memory);

    /// @notice Returns the deployment configuration
    /// @return The Config struct containing deployment parameters
    function getConfig() external view returns (Config memory);
}
