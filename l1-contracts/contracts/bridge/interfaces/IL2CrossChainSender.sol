// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {InteropCallStarter} from "../../common/Messaging.sol";

/// @title L2 Cross Chain Sender interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2CrossChainSender {
    /// @notice Builds the destination call for an indirect interop send.
    /// @param _chainId Destination chain ID.
    /// @param _originalCaller Sender of the initiating Interop Center call.
    /// @param _value Base-token value delivered to the destination call.
    /// @param _data The calldata for the cross-chain sender deposit.
    /// @return interopCallStarter InteropCallStarter corresponding to the cross-chain sender call.
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (InteropCallStarter memory interopCallStarter);
}
