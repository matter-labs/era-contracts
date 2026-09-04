// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {InteropCallStarter} from "../common/Messaging.sol";
import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";

/// @title Shared Interop Center interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Common message-sending surface exposed by the L1 and L2 Interop Centers.
/// @dev Transport semantics are layer-specific: L2 sends interop bundles through the L2-to-L1 messenger,
/// while L1 accepts only single-call bundles and delivers them as priority transactions through the
/// destination chain's Mailbox.
interface IInteropCenterBase is IERC7786GatewaySource {
    /// @notice Sends a collection of calls to one destination chain.
    /// @param _destinationChainId ERC-7930 destination with an empty address field.
    /// @param _callStarters Calls to send. Each `to` address must have an empty chain-reference field.
    /// @param _bundleAttributes Attributes applying to the transport or the complete collection of calls.
    /// @return bundleHash L2 returns the interop bundle hash; L1 returns the canonical priority-transaction hash.
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable returns (bytes32 bundleHash);

    /// @notice Pauses the message-sending entry points.
    function pause() external;

    /// @notice Unpauses the message-sending entry points.
    function unpause() external;
}
