// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {Transaction} from "../libraries/TransactionHelper.sol";
import {MessageInclusionProof} from "../libraries/Messaging.sol";

struct InteropCall {
    address to;
    address from;
    uint256 value;
    bytes data;
}

struct InteropBundle {
    uint256 destinationChainId;
    InteropCall[] calls;
    // If not set - anyone can execute it.
    address[] executionAddresses;
    // Who can 'cancel' this bundle.
    address cancellationAddress;
}

interface IInteropHandler {
    function setInteropAccountBytecode() external;
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bool _skipEmptyCalldata) external;
}
