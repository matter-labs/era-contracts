// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IEnableEvmEmulator
/// @notice Interface for EnableEvmEmulator.s.sol script
/// @dev This interface ensures selector visibility for EVM emulator functions
interface IEnableEvmEmulator {
    function chainAllowEvmEmulation(address chainAdmin, address target) external;
}
