// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IDeployGatewayTransactionFilterer
/// @notice Interface for DeployGatewayTransactionFilterer.s.sol script
/// @dev This interface ensures selector visibility for gateway transaction filterer deployment
/// Both create2FactoryAddress and create2FactorySalt are read from permanent-values.toml
interface IDeployGatewayTransactionFilterer {
    function run(address bridgehub, address chainAdmin, address chainProxyAdmin) external returns (address proxy);

    function runWithInputFromFile() external;
}
