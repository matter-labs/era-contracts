// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {InteropCallStarter} from "../../common/Messaging.sol";

/// @title L2 Cross Chain Sender interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2CrossChainSender {
    /// @notice Function that returns an InteropCallStarter corresponding to the interop call. Effectively this initiates bridging,
    ///         BH part is processed within this function via `_bridgehubDeposit` call which also returns the data for an l2 call
    ///         on the destination chain (which will be processed with the returned InteropCallStarter from this function).
    /// @param _chainId Destination chain ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _value The `msg.value` to be deposited on the target chain.
    /// @param _data The calldata for the second bridge deposit.
    /// @return interopCallStarter InteropCallStarter corresponding to the second bridge call.
    function initiateBridging(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (InteropCallStarter memory interopCallStarter);
}
