// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {BundleStatus, CallStatus, MessageInclusionProof} from "../common/Messaging.sol";

/// @title IInteropHandlerBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The environment-independent part of the interop handler interface: bundle verification and
/// execution. Implemented by the L2 `InteropHandler` predeploy and the `L1InteropHandler` (which
/// executes L2->L1 withdrawal bundles on L1).
interface IInteropHandlerBase {
    event BundleVerified(bytes32 indexed bundleHash);

    event BundleExecuted(bytes32 indexed bundleHash);

    /// @notice Executes a full bundle atomically.
    /// @dev Reverts if any call fails, or if bundle has been processed already.
    /// @param _bundle ABI-encoded InteropBundle to execute.
    /// @param _proof Inclusion proof for the bundle message.
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;

    /// @notice Verifies receipt of a bundle without executing calls.
    /// @dev Marks bundle as Verified on success.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _proof Inclusion proof for the bundle message.
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;

    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Tracks the processing status of a bundle by its hash.
    function bundleStatus(bytes32 bundleHash) external view returns (BundleStatus);

    /// @notice Tracks the individual call statuses within a bundle.
    function callStatus(bytes32 bundleHash, uint256 callIndex) external view returns (CallStatus);
}
