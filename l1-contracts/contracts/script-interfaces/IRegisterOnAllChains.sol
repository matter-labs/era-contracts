// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IRegisterOnAllChains
/// @notice Interface for RegisterOnAllChains.s.sol script
interface IRegisterOnAllChains {
    function registerOnOtherChains(address _bridgehub, uint256 _chainId) external;
}
