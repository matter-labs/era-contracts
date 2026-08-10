// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {InteropCallStarter} from "../../common/Messaging.sol";

/// @title L2 Cross Chain Sender interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2CrossChainSender {
    /// @notice Function that returns an InteropCallStarter corresponding to the interop call. Effectively this initiates a two step call,
    ///         where there is a middleman in the InteropCall. The expected usage is as follows:
    ///         We call initiateIndirectCall on contract A on source chain. It returns an interopCallStarter which will be used to pass the call
    ///         to the destination chain. In this second call the sender is contract A on source chain. This "indirect" call mechanism could be used for complex
    ///         Interop scenarios, such as bridging.
    /// @param _chainId Destination chain ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _value The `msg.value` to be deposited on the target chain.
    /// @param _data The calldata for the second bridge deposit.
    /// @return interopCallStarter InteropCallStarter corresponding to the second bridge call.
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (InteropCallStarter memory interopCallStarter);
}
