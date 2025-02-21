// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {L2Log} from "../../common/Messaging.sol";

interface IAssetTracker {
    function handleChainBalanceIncrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function handleChainBalanceDecrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function processLogsAndMessages(L2Log[] calldata _logs, bytes[] calldata _messages, bytes32) external;
}
