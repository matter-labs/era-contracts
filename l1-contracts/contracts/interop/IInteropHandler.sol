// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {CallStatus, MessageInclusionProof} from "../common/Messaging.sol";

interface IInteropHandler {
    event BundleVerified(bytes32 indexed bundleHash);

    event BundleExecuted(bytes32 indexed bundleHash);

    event BundleUnbundled(bytes32 indexed bundleHash);

    event CallProcessed(bytes32 indexed bundleHash, uint256 indexed callIndex, CallStatus status);

    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;

    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;

    function unbundleBundle(uint256 _sourceChainId, bytes memory _bundle, CallStatus[] calldata _callStatus) external;
}
