// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title ISetupLegacyBridge
/// @notice Interface for SetupLegacyBridge.s.sol script
/// @dev Both create2FactoryAddr and create2FactorySalt are read from permanent-values.toml within the script
interface ISetupLegacyBridge {
    function run(address _bridgehub, uint256 _chainId) external;
}
