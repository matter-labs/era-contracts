// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IDeployGatewayTransactionFilterer
/// @notice Interface for DeployGatewayTransactionFilterer.s.sol script
/// @dev This interface ensures selector visibility for gateway transaction filterer deployment
interface IDeployGatewayTransactionFilterer {
    function run(
        address bridgehub,
        address chainAdmin,
        address chainProxyAdmin,
        address create2FactoryAddress,
        bytes32 create2FactorySalt
    ) external returns (address proxy);

    function runWithInputFromFile() external;
}
