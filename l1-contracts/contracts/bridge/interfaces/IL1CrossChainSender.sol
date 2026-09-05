// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IndirectCallRequest} from "../../common/Messaging.sol";

/// @title L1 Cross Chain Sender interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1CrossChainSender {
    /// @notice Builds an indirect priority request for the authorized L1 Interop Center.
    /// @param _chainId Destination chain ID.
    /// @param _originalCaller Sender of the initiating Interop Center call.
    /// @param _value Base-token value delivered to the destination call.
    /// @param _data The indirect call payload.
    /// @return request Destination call and confirmation data returned to the L1 Interop Center.
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (IndirectCallRequest memory request);

    /// @notice Handles the canonical hash after the Mailbox accepts the indirect request.
    /// Only the registered L1 Interop Center may confirm a request.
    /// @param _chainId Destination chain ID.
    /// @param _txDataHash Sender-specific confirmation hash returned in the request.
    /// @param _txHash The canonical priority-transaction hash.
    function confirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;
}
