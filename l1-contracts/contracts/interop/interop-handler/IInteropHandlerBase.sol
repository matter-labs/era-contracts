// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {BundleStatus, CallStatus} from "../../common/Messaging.sol";

/// @notice Proof-agnostic surface of the interop handlers, shared by {InteropHandlerBase}.
/// @dev `executeBundle`/`verifyBundle` are intentionally NOT declared here: the L2 handler takes an
/// `AtomicFinalityProof` and the L1 handler a `MessageInclusionProof`, so each derived contract declares its
/// own proof-typed entry point. Only the proof-agnostic parts (unbundle, status, events) live here.
interface IInteropHandlerBase {
    event BundleVerified(bytes32 indexed bundleHash);

    event BundleExecuted(bytes32 indexed bundleHash);

    event BundleUnbundled(bytes32 indexed bundleHash);

    event CallProcessed(bytes32 indexed bundleHash, uint256 indexed callIndex, CallStatus status);

    /// @notice Function used to unbundle the bundle. It's present to give more flexibility in cancelling and overall processing of bundles.
    ///         Can be invoked multiple times until all calls are processed.
    /// @dev This function does not verify the validity of the bundle, as it's assumed it was already checked inside `verifyBundle`.
    /// @param _bundle ABI-encoded InteropBundle to unbundle.
    /// @param _callStatus Array of desired statuses per call.
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _callStatus) external;

    /// @notice Tracks the processing status of a bundle by its hash.
    function bundleStatus(bytes32 bundleHash) external view returns (BundleStatus);

    /// @notice Tracks the individual call statuses within a bundle.
    function callStatus(bytes32 bundleHash, uint256 callIndex) external view returns (CallStatus);
}
