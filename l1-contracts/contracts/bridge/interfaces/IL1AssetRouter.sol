// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IL1ERC20Bridge} from "./IL1ERC20Bridge.sol";
import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";
import {IL1Nullifier} from "./IL1Nullifier.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter {
    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        bytes32 assetId,
        bytes l2BridgeMintCalldata
    );

    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        bytes32 assetId,
        uint256 amount
    );

    event BridgehubMintData(bytes bridgeMintData);

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event WithdrawalFinalizedSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        uint256 amount
    );

    event ClaimedFailedDepositSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        bytes assetData
    );

    event AssetHandlerRegisteredInitial(
        bytes32 indexed assetId,
        address indexed assetHandlerAddress,
        bytes32 indexed additionalData,
        address sender
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed assetHandlerAddress);

    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external returns (address l1Receiver, bytes32 assetId, uint256 amount);

    function BRIDGE_HUB() external view returns (IBridgehub);

    /// data is abi encoded :
    /// address _l1Token,
    /// uint256 _amount,
    /// address _l2Receiver
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) external payable;

    function setAssetHandlerAddressInitial(bytes32 _additionalData, address _assetHandlerAddress) external;

    function setAssetHandlerAddressOnCounterPart(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient,
        bytes32 _assetId,
        address _assetAddressOnCounterPart
    ) external payable returns (bytes32 l2TxHash);

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function nativeTokenVault() external view returns (IL1NativeTokenVault);

    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external;

    function setL1Nullifier(IL1Nullifier _l1Nullifier) external;

    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function bridgeRecoverFailedTransfer(
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
        address _l1Sender,
        bytes32 _assetId,
        bytes memory _transferData
    ) external view returns (bytes memory);
}
