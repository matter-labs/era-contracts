// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {BundleStatus, CallStatus} from "../common/Messaging.sol";
import {AtomicFinalityProof} from "../atomic-interop/IAtomicInterop.sol";

interface IInteropHandler {
    event BundleVerified(bytes32 indexed bundleHash);

    event BundleExecuted(bytes32 indexed bundleHash);

    event BundleUnbundled(bytes32 indexed bundleHash);

    event CallProcessed(bytes32 indexed bundleHash, uint256 indexed callIndex, CallStatus status);

    /// @notice Executes a full **atomic interop** bundle atomically. Instead of an L1-message inclusion
    /// proof it requires (via the AtomicFlowManager) that every leg of the flow was committed in its
    /// source chain's IMT before the deadline. Interop is atomic-only: bundles are never published to L1.
    /// @dev Reverts if any call fails, or if the bundle has been processed already.
    /// @param _bundle ABI-encoded InteropBundle to execute (must carry the `atomicBundle` attribute).
    /// @param _finality The flow definition (`flowId`, legs, deadline) + one IMT inclusion proof per leg.
    function executeBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) external;

    /// @notice Verifies receipt of an atomic bundle without executing calls.
    /// @dev Marks bundle as Verified on success, enabling the verify->unbundle flow.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _finality The flow definition + one IMT inclusion proof per leg.
    function verifyBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) external;

    /// @notice Function used to unbundle the bundle. It's present to give more flexibility in cancelling and overall processing of bundles.
    ///         Can be invoked multiple times until all calls are processed.
    /// @dev This function does not verify the validity of the bundle, as it's assumed it was already checked inside `verifyBundle`.
    /// @param _bundle ABI-encoded InteropBundle to unbundle.
    /// @param _callStatus Array of desired statuses per call.
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _callStatus) external;

    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Tracks the processing status of a bundle by its hash.
    function bundleStatus(bytes32 bundleHash) external view returns (BundleStatus);

    /// @notice Tracks the individual call statuses within a bundle.
    function callStatus(bytes32 bundleHash, uint256 callIndex) external view returns (CallStatus);

    /// @notice Initializes the reentrancy guard.
    /// @param _l1ChainId The chain ID of L1.
    function initL2(uint256 _l1ChainId) external;
}
