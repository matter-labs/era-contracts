// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title ISetupLegacyBridge
/// @notice Interface for SetupLegacyBridge.s.sol script
/// @dev create2 factory parameters are initialized via Create2FactoryUtils
interface ISetupLegacyBridge {
    function run(address _bridgehub, uint256 _chainId) external;
}
