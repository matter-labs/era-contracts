// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC7786Recipient} from "./IERC7786Recipient.sol";

/// @dev The type of call a ShadowAccount can execute.
/// @param Call Standard external call.
/// @param DelegateCall Delegatecall — runs target code in the ShadowAccount's context.
enum ShadowAccountCallType {
    Call,
    DelegateCall
}

/// @dev A single call to be executed by a ShadowAccount.
/// @param callType Whether to use call or delegatecall.
/// @param target Address to call.
/// @param value ETH value to send (only for Call type; ignored for DelegateCall).
/// @param data Calldata payload.
struct ShadowAccountCall {
    ShadowAccountCallType callType;
    address target;
    uint256 value;
    bytes data;
}

/// @title IShadowAccount
/// @notice Interface for shadow accounts — remote smart accounts controlled by a home-chain owner via interop.
interface IShadowAccount is IERC7786Recipient {
    /// @notice Emitted when the shadow account is initialized with its owner.
    event ShadowAccountInitialized(bytes owner);

    /// @notice Emitted when a call is successfully executed by the shadow account.
    event ShadowAccountCallExecuted(uint256 indexed callIndex, ShadowAccountCallType callType, address target);

    /// @notice Returns the ERC-7930 encoded owner address.
    function owner() external view returns (bytes memory);

    /// @notice Initializes the shadow account with the given owner.
    /// @dev Can only be called once, by the factory.
    /// @param _owner ERC-7930 encoded address of the owner on the home chain.
    function initialize(bytes calldata _owner) external;
}
