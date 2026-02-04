// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IRegisterCTM
/// @notice Interface for RegisterCTM.s.sol script
interface IRegisterCTM {
    function registerCTM(address bridgehub, address chainTypeManagerProxy, bool shouldSend) external;
}
