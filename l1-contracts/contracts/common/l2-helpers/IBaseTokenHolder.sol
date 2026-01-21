// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IBaseTokenHolder
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the BaseTokenHolder contract that holds the chain's base token reserves.
interface IBaseTokenHolder {
    event BaseTokenGiven(address indexed to, uint256 amount);
    event BaseTokenReceived(address indexed from, uint256 amount);

    function give(address _to, uint256 _amount) external;
    function receive_() external payable;
}
