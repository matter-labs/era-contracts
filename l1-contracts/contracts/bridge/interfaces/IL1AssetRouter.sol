// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IL1ERC20Bridge} from "./IL1ERC20Bridge.sol";
import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter {
    event LegacyDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address to,
        address l1Asset,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        bytes32 assetId,
        bytes bridgeMintCalldata
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

    function isWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex
    ) external view returns (bool);

    function depositLegacyErc20Bridge(
        address _msgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash);

    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external returns (address l1Receiver, address l1Token, uint256 amount);

    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

    function L1_WETH_TOKEN() external view returns (address);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function legacyBridge() external view returns (IL1ERC20Bridge);

    function depositHappened(uint256 _chainId, bytes32 _l2TxHash) external view returns (bytes32);

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

    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function hyperbridgingEnabled(uint256 _chainId) external view returns (bool);

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

    function chainBalance(uint256 _chainId, address _token) external view returns (uint256);

    function transferTokenToNTV(address _token) external;

    function transferBalanceToNTV(uint256 _chainId, address _token) external;
}
