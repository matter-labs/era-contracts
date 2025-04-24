// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {MessageInclusionProof, InteropCall, InteropBundle} from "../libraries/Messaging.sol";

interface IInteropHandler {
    function setInteropAccountBytecode() external;
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bool _skipEmptyCalldata) external;
}
