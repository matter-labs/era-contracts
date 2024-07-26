// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../../bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL1Nullifier} from "./IL1Nullifier.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter is IAssetRouterBase {
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

    function setL1Nullifier(IL1Nullifier _l1Nullifier) external;

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

    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external;

    function depositLegacyErc20Bridge(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 l2TxHash);
}
