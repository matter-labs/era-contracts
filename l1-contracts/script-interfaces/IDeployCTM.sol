// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Config, CTMDeployedAddresses} from "../deploy-scripts/ctm/DeployCTMUtils.s.sol";

/// @title IDeployCTM
/// @notice Interface for the Chain Type Manager (CTM) deployment script
interface IDeployCTM {
    /// @notice Runs the deployment with default paths
    function run() external;

    /// @notice Runs the deployment with a specific bridgehub
    /// @param bridgehub The address of the bridgehub contract
    /// @param reuseGovAndAdmin Whether to reuse existing governance and admin contracts
    function runWithBridgehub(address bridgehub, bool reuseGovAndAdmin) external;

    /// @notice Runs the deployment for testing purposes
    /// @param bridgehub The address of the bridgehub contract
    /// @param skipL1Deployments Whether to skip L1 contract deployments
    function runForTest(address bridgehub, bool skipL1Deployments) external;

    /// @notice Returns the deployed contract addresses
    /// @return The CTMDeployedAddresses struct containing all deployed addresses
    function getAddresses() external view returns (CTMDeployedAddresses memory);

    /// @notice Returns the deployment configuration
    /// @return The Config struct containing deployment parameters
    function getConfig() external view returns (Config memory);

    /// @notice Saves the diamond selectors to a file
    function saveDiamondSelectors() external;
}
