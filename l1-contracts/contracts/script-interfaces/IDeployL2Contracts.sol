// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDeployL2Contracts
/// @notice Interface for the L2 Contracts deployment script
interface IDeployL2Contracts {
    /// @notice Runs the deployment with specified bridgehub and chain ID
    /// @param _bridgehub The address of the bridgehub contract
    /// @param _chainId The chain ID for the L2 deployment
    function run(address _bridgehub, uint256 _chainId) external;

    /// @notice Runs the deployment with legacy bridge support
    /// @param _bridgehub The address of the bridgehub contract
    /// @param _chainId The chain ID for the L2 deployment
    function runWithLegacyBridge(address _bridgehub, uint256 _chainId) external;

    /// @notice Deploys L2 contracts
    /// @param legacyBridge Whether to include legacy bridge support
    function deploy(bool legacyBridge) external;

    /// @notice Runs the default upgrader deployment
    /// @param _bridgehub The address of the bridgehub contract
    /// @param _chainId The chain ID for the L2 deployment
    function runDefaultUpgrader(address _bridgehub, uint256 _chainId) external;

    /// @notice Runs the consensus registry deployment
    /// @param _bridgehub The address of the bridgehub contract
    /// @param _chainId The chain ID for the L2 deployment
    function runDeployConsensusRegistry(address _bridgehub, uint256 _chainId) external;

    /// @notice Runs the Multicall3 deployment
    /// @param _bridgehub The address of the bridgehub contract
    /// @param _chainId The chain ID for the L2 deployment
    function runDeployMulticall3(address _bridgehub, uint256 _chainId) external;

    /// @notice Runs the timestamp asserter deployment
    /// @param _bridgehub The address of the bridgehub contract
    /// @param _chainId The chain ID for the L2 deployment
    function runDeployTimestampAsserter(address _bridgehub, uint256 _chainId) external;
}
