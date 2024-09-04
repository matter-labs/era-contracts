// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

// import {L2TransactionRequestDirect} from "../../bridgehub/IBridgehub.sol";
// import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
// import {IL1ERC20Bridge} from "./IL1ERC20Bridge.sol";

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

    // function isWithdrawalFinalized(
    //     uint256 _chainId,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2ToL1MessageNumber
    // ) external view returns (bool);

    // function depositLegacyErc20Bridge(
    //     address _prevMsgSender,
    //     address _l2Receiver,
    //     address _l1Token,
    //     uint256 _amount,
    //     uint256 _l2TxGasLimit,
    //     uint256 _l2TxGasPerPubdataByte,
    //     address _refundRecipient
    // ) external payable returns (bytes32 txHash);

    // function claimFailedDeposit(
    //     uint256 _chainId,
    //     address _depositSender,
    //     address _l1Token,
    //     uint256 _amount,
    //     bytes32 _l2TxHash,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes32[] calldata _merkleProof
    // ) external;

    // function finalizeWithdrawalLegacyErc20Bridge(
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes calldata _message,
    //     bytes32[] calldata _merkleProof
    // ) external returns (address l1Receiver, address l1Asset, uint256 amount);

    // function finalizeWithdrawal(
    //     uint256 _chainId,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes calldata _message,
    //     bytes32[] calldata _merkleProof
    // ) external;

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_WETH_TOKEN() external view returns (address);

    // function BRIDGE_HUB() external view returns (IBridgehub);

    // function legacyBridge() external view returns (IL1ERC20Bridge);

    // function depositHappened(uint256 _chainId, bytes32 _l2DepositTxHash) external view returns (bytes32);

    // function hyperbridgingEnabled(uint256 _chainId) external view returns (bool);

    function setAssetDeploymentTracker(bytes32 _assetRegistrationData, address _assetDeploymentTracker) external;

    // function setAssetHandlerAddressThisChain(bytes32 _additionalData, address _assetHandlerAddress) external;

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(address _sender, bytes32 _assetId, address _assetAddress) external;

    // function setL1Nullifier(IL1Nullifier _l1Nullifier) external;

    function setNativeTokenVault(INativeTokenVault _nativeTokenVault) external;

    // function bridgehubWithdraw(
    //     uint256 _chainId,
    //     address _prevMsgSender,
    //     bytes32 _assetId,
    //     bytes calldata _transferData
    // ) external returns (L2TransactionRequestTwoBridgesInner memory request);

    // function finalizeDeposit(
    //     uint256 _chainId,
    //     bytes32 _assetId,
    //     bytes calldata _transferData
    // ) external returns (address l1Receiver, uint256 amount);

    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external;

    // function depositLegacyErc20Bridge(
    //     L2TransactionRequestDirect calldata _request
    // ) external payable returns (bytes32 l2TxHash);

    //     bytes calldata _assetData,
    //     bytes32 _l2TxHash,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes32[] calldata _merkleProof
    // ) external;

    // function chainBalance(uint256 _chainId, address _l1Token) external view returns (uint256);

    // function transferTokenToNTV(address _token) external;

    function transferAllowanceToNTV(bytes32 _assetId, uint256 _amount, address _prevMsgSender) external;

    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes memory _transferData
    ) external returns (address l1Receiver, uint256 amount);
}
