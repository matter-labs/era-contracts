// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {MessageInclusionProof} from "../libraries/Messaging.sol";

enum CallStatus {
    Unprocessed,
    Executed,
    Cancelled
}

enum BundleStatus {
    Unreceived,
    Verified,
    FullyExecuted,
    Unbundled
}

interface IInteropHandler {
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;
    function unbundleBundle(
        uint256 _sourceChainId,
        uint256 _l2MessageIndex,
        bytes memory _bundle,
        CallStatus[] calldata _callStatus
    ) external;
}
