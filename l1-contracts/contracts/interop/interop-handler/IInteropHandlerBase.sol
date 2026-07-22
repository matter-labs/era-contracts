// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {BundleStatus, CallStatus} from "../../common/Messaging.sol";

/// @notice Proof-agnostic surface of the interop handlers, shared by {InteropHandlerBase}.
/// @dev `executeBundle`/`verifyBundle` are intentionally NOT declared here: the L2 handler takes an
/// `AtomicFinalityProof` and the L1 handler a `MessageInclusionProof`, so each derived contract declares its
/// own proof-typed entry point. Only the proof-agnostic parts (unbundle, status, events) live here.
interface IInteropHandlerBase {
    /// @notice Emitted when a bundle is marked Verified.
    event BundleVerified(bytes32 indexed bundleHash);

    /// @notice Emitted when a bundle is fully executed.
    event BundleExecuted(bytes32 indexed bundleHash);

    /// @notice Emitted when a bundle is (partially) processed via unbundling.
    event BundleUnbundled(bytes32 indexed bundleHash);

    /// @notice Emitted for each call whose status changes during unbundling.
    event CallProcessed(bytes32 indexed bundleHash, uint256 indexed callIndex, CallStatus status);

    /// @notice Executes, cancels or skips a bundle's calls individually; may be invoked multiple times until
    /// all calls are processed. See {protocol-docs/interop.md} (unbundling).
    /// @dev Does not verify the validity of the bundle itself: it requires the bundle to have been verified
    /// via `verifyBundle` first.
    /// @param _bundle ABI-encoded InteropBundle to unbundle.
    /// @param _callStatus Array of desired statuses per call.
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _callStatus) external;

    /// @notice Tracks the processing status of a bundle by its hash.
    function bundleStatus(bytes32 bundleHash) external view returns (BundleStatus);

    /// @notice Tracks the individual call statuses within a bundle.
    function callStatus(bytes32 bundleHash, uint256 callIndex) external view returns (CallStatus);
}
