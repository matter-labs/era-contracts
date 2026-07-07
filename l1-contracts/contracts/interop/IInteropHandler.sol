// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {CallStatus} from "../common/Messaging.sol";
import {IInteropHandlerBase} from "./IInteropHandlerBase.sol";

interface IInteropHandler is IInteropHandlerBase {
    event BundleUnbundled(bytes32 indexed bundleHash);

    event CallProcessed(bytes32 indexed bundleHash, uint256 indexed callIndex, CallStatus status);

    /// @notice Function used to unbundle the bundle. It's present to give more flexibility in cancelling and overall processing of bundles.
    ///         Can be invoked multiple times until all calls are processed.
    /// @dev This function does not verify the validity of the bundle, as it's assumed it was already checked inside `verifyBundle`.
    /// @param _bundle ABI-encoded InteropBundle to unbundle.
    /// @param _callStatus Array of desired statuses per call.
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _callStatus) external;

    /// @notice Initializes the reentrancy guard.
    /// @param _l1ChainId The chain ID of L1.
    function initL2(uint256 _l1ChainId) external;
}
