// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";

/// @title Shared Interop Center interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Common surface exposed by the L1 and L2 Interop Centers: the ERC-7786 `sendMessage` entry point
/// (inherited from {IERC7786GatewaySource}) and the owner-controlled pause switch.
/// @dev Transport semantics are layer-specific: L2 wraps the message into an interop bundle, while L1 delivers it
/// as a priority transaction through the destination chain's Mailbox. Multi-call bundles (`sendBundle`) exist only
/// on L2 (see {IInteropCenter}); an L1->L2 message always maps to exactly one priority transaction.
interface IInteropCenterBase is IERC7786GatewaySource {
    /// @notice Pauses the message-sending entry points.
    function pause() external;

    /// @notice Unpauses the message-sending entry points.
    function unpause() external;
}
