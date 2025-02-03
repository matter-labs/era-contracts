// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetTrackerBase} from "./IAssetTrackerBase.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

error InvalidMessage();
contract AssetTrackerBase is IAssetTrackerBase {
    // function handleChainBalanceIncrease(
    //     uint256 _chainId,
    //     bytes32 _assetId,
    //     uint256 _amount,
    //     bool _isNative
    // ) external virtual;

    // function handleChainBalanceDecrease(
    //     uint256 _chainId,
    //     bytes32 _assetId,
    //     uint256 _amount,
    //     bool _isNative
    // ) external virtual;

    /// note we don't process L1 txs here, since we can do that when accepting the tx. 
    function processLogsAndMessages(L2Log[] calldata _logs, bytes[] calldata _messages, bytes32) external {
        uint256 msgCount = 0;
        for (uint256 i = 0; i < _logs.length; i++) {
            L2Log memory log = _logs[i];
            if (log.sender != L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR || log.key != bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))) {
                continue;
            }
            bytes calldata message = _messages[msgCount];
            if (log.value != keccak256(message)) {
                revert InvalidMessage();
            }
            
            msgCount++;
        }
    }
}