// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetTrackerBase} from "./IAssetTrackerBase.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InteropBundle, InteropCall} from "../../common/Messaging.sol";

error InvalidMessage();
contract AssetTrackerBase is IAssetTrackerBase {
    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;


    mapping(uint256 chainId => mapping(bytes32 assetId => bool isMinter)) public isMinterChain;

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
            bytes memory message = _messages[msgCount];
            if (log.value != keccak256(message)) {
                revert InvalidMessage();
            }

            InteropBundle memory interopBundle = abi.decode(message, (InteropBundle));

            // handle msg.value call separately
            InteropCall memory interopCall = interopBundle.calls[0];
            for (uint256 i = 1; i < interopBundle.calls.length; i++) {
                if (interopCall.data[0:4] != IAssetRouterBase.finalizeDeposit.selector) {
                    revert InvalidMessage();
                }

                (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = abi.decode(interopCall.data[4:], (uint256, bytes32, bytes));
                (, ,, uint256 amount,) = DataEncoding.decodeBridgeMintData(transferData);
                if (isMinterChain[fromChainId][assetId]) {
                    chainBalance[fromChainId][assetId] -= amount;
                }
                if (isMinterChain[interopBundle.destinationChainId][assetId]) {
                    chainBalance[interopBundle.destinationChainId][assetId] += amount;
                }
            }

            // kl todo add L1<>L2 messaging here
            // kl todo add change minter role here
            msgCount++;
        }
    }
}