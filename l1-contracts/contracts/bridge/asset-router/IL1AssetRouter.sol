// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter {
    event BridgehubMintData(bytes bridgeMintData);

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event ClaimedFailedDepositAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    event WithdrawalFinalizedAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    event AssetDeploymentTrackerSet(
        bytes32 indexed assetId,
        address indexed assetDeploymentTracker,
        bytes32 indexed additionalData
    );

    event LegacyDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address to,
        address l1Asset,
        uint256 amount
    );

    function depositLegacyErc20Bridge(
        address _msgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash);

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_WETH_TOKEN() external view returns (address);

    function setAssetDeploymentTracker(bytes32 _assetRegistrationData, address _assetDeploymentTracker) external;

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(address _sender, bytes32 _assetId, address _assetAddress) external;

    function setNativeTokenVault(INativeTokenVault _nativeTokenVault) external;

    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external;

    function transferAllowanceToNTV(bytes32 _assetId, uint256 _amount, address _prevMsgSender) external;

    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external returns (address l1Receiver, address l1Token, uint256 amount);

    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes memory _transferData
    ) external returns (address l1Receiver, uint256 amount);
}
