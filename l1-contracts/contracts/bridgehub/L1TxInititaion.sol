// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner, RouteBridgehubDepositStruct} from "./IBridgehub.sol";
import {MsgValueMismatch, Unauthorized, WrongMagicValue, BridgehubOnL1} from "../common/L1ContractErrors.sol";
import {BridgehubL2TransactionRequest, L2CanonicalTransaction, L2Message, L2Log, TxStatus, InteropCallStarter, InteropCall, BundleMetadata, InteropBundle, InteropTrigger, GasFields, InteropCallRequest, BUNDLE_IDENTIFIER, TRIGGER_IDENTIFIER} from "../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER, INTEROP_OPERATION_TX_TYPE, INSERT_MSG_ADDRESS_ON_DESTINATION} from "../common/Config.sol";
import {NotL1, NotRelayedSender, DirectCallNonEmptyValue, NotAssetRouter, ChainIdAlreadyPresent, ChainNotPresentInCTM, SecondBridgeAddressTooLow, NotInGatewayMode, SLNotWhitelisted, IncorrectChainAssetId, NotCurrentSL, HyperchainNotRegistered, IncorrectSender, AlreadyCurrentSL, ChainNotLegacy} from "./L1BridgehubErrors.sol";

abstract contract L1TxInititaion {
    /// @notice the mailbox is called directly after the assetRouter received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the nativeTokenVault.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token.
    /// In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    function _requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request, 
        bytes32 _baseTokenAssetId,
        bytes32 _ethTokenAssetId,
        address _assetRouter
    ) internal returns (bytes32 canonicalTxHash) {
        // Note: If the ZK chain with corresponding `chainId` is not yet created,
        // the transaction will revert on `bridgehubRequestL2Transaction` as call to zero address.
        {
            if (_baseTokenAssetId == _ethTokenAssetId || _baseTokenAssetId == bytes32(0)) {
                if (msg.value != _request.mintValue) {
                    revert MsgValueMismatch(_request.mintValue, msg.value);
                }
            } else {
                if (msg.value != 0) {
                    revert MsgValueMismatch(0, msg.value);
                }
            }

            // slither-disable-next-line arbitrary-send-eth
            IAssetRouterBase(_assetRouter).bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                _baseTokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }

        canonicalTxHash = _sendRequest(
            _request.chainId,
            _request.refundRecipient,
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _request.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: _request.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: address(0)
            })
        );
    }

    function _requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request,
        bytes32 _baseTokenAssetId, 
        bytes32 _ethTokenAssetId,
        address _assetRouter
    ) internal returns (bytes32 canonicalTxHash) {
        if (_request.secondBridgeAddress <= BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS) {
            revert SecondBridgeAddressTooLow(_request.secondBridgeAddress, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS);
        }

        {
            uint256 baseTokenMsgValue;
            if (_baseTokenAssetId == _ethTokenAssetId || _baseTokenAssetId == bytes32(0)) {
                if (msg.value != _request.mintValue + _request.secondBridgeValue) {
                    revert MsgValueMismatch(_request.mintValue + _request.secondBridgeValue, msg.value);
                }
                baseTokenMsgValue = _request.mintValue;
            } else {
                if (msg.value != _request.secondBridgeValue) {
                    revert MsgValueMismatch(_request.secondBridgeValue, msg.value);
                }
                baseTokenMsgValue = 0;
            }

            // slither-disable-next-line arbitrary-send-eth
            IAssetRouterBase(_assetRouter).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _request.chainId,
                _baseTokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }
        L2TransactionRequestTwoBridgesInner memory outputRequest;
        // slither-disable-next-line arbitrary-send-eth
        outputRequest = IAssetRouterBase(_request.secondBridgeAddress).bridgehubDeposit{
            value: _request.secondBridgeValue
        }(_request.chainId, msg.sender, _request.l2Value, _request.secondBridgeCalldata);


        if (outputRequest.magicValue != TWO_BRIDGES_MAGIC_VALUE) {
            revert WrongMagicValue(uint256(TWO_BRIDGES_MAGIC_VALUE), uint256(outputRequest.magicValue));
        }

        canonicalTxHash = _sendRequest(
            _request.chainId,
            _request.refundRecipient,
            BridgehubL2TransactionRequest({
                sender: _request.secondBridgeAddress,
                contractL2: outputRequest.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: outputRequest.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: outputRequest.factoryDeps,
                refundRecipient: address(0)
            })
        );

        // if (_request.secondBridgeAddress == address(assetRouter)) {
            IAssetRouterBase(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
                _request.chainId,
                outputRequest.txDataHash,
                canonicalTxHash
            );
        // } else {
        //     BRIDGE_HUB.routeBridgehubConfirmL2Transaction(
        //         _request.secondBridgeAddress,
        //         _request.chainId,
        //         outputRequest.txDataHash,
        //         canonicalTxHash
        //     );
        // }
    }

    function _sendRequest(
        uint256 _chainId,
        address _refundRecipient,
        BridgehubL2TransactionRequest memory _request
    ) internal virtual returns (bytes32 canonicalTxHash);
}
