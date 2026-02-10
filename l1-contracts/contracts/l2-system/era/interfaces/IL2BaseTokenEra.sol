// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {IL2BaseTokenBase} from "../../interfaces/IL2BaseTokenBase.sol";

/// @title IL2BaseTokenEra
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the L2 Base Token contract on Era chains.
/// @dev Extends IL2BaseTokenBase with Era-specific functionality (balance management, mint, transferFromTo).
interface IL2BaseTokenEra is IL2BaseTokenBase {
    /// @notice Emitted when tokens are minted
    event Mint(address indexed account, uint256 amount);

    /// @notice Emitted when tokens are transferred
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Returns ETH balance of an account
    /// @param _account The address of the account (as uint256 for BALANCE opcode compatibility)
    function balanceOf(uint256 _account) external view returns (uint256);

    /// @notice Transfer tokens from one address to another
    /// @param _from The address to transfer the ETH from
    /// @param _to The address to transfer the ETH to
    /// @param _amount The amount of ETH in wei being transferred
    function transferFromTo(address _from, address _to, uint256 _amount) external;

    /// @notice Returns the total circulating supply of base tokens
    function totalSupply() external view returns (uint256);

    /// @notice Increase the balance of the receiver by transferring from BaseTokenHolder
    /// @param _account The address which to mint the funds to
    /// @param _amount The amount of ETH in wei to be minted
    function mint(address _account, uint256 _amount) external;
}
