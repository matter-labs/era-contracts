// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {INullifier} from "./INullifier.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter {
    event ClaimedFailedDepositSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        bytes assetData
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed assetHandlerAddress);

    event WithdrawalFinalizedAssetRouter(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        uint256 amount
    );

    function setAssetHandlerAddressOnCounterPart(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient,
        bytes32 _assetId,
        address _assetAddressOnCounterPart
    ) external payable returns (bytes32 l2TxHash);

    function setL1Nullifier(INullifier _l1Nullifier) external;

    function bridgehubWithdraw(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external returns (L2TransactionRequestTwoBridgesInner memory request);

    function finalizeWithdrawal(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external returns (address l1Receiver, uint256 amount);

    function bridgeRecoverFailedTransfer(
        bool _checkedInLegacyBridge,
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _tokenData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    function _getDepositL2Calldata(
        uint256 _chainId,
        address _l1Sender,
        bytes32 _assetId,
        bytes memory _transferData
    ) external view returns (bytes memory);
}
