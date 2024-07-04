// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAssetRouterBase {
    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        bytes32 assetId,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        bytes32 assetId,
        bytes bridgeMintCalldata
    );

    event BridgehubWithdrawalInitiated(
        uint256 chainId,
        address indexed sender,
        bytes32 indexed assetId,
        bytes32 assetDataHash // What's the point of emitting hash?
    );

    event DepositFinalizedAssetRouter(uint256 chainId, bytes32 indexed assetId, bytes32 assetDataHash); // why hash? shall we make it similar to WithdrawalFinalizedAssetRouter?

    event WithdrawalFinalizedAssetRouter(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        uint256 amount
    );

    event AssetHandlerRegistered(
        bytes32 indexed assetId,
        address indexed assetHandlerAddress,
        bytes32 assetData,
        address assetDeploymentTracker
    );

    function BRIDGE_HUB() external view returns (IBridgehub);

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) external payable;

    /// data is abi encoded :
    /// address _l1Token,
    /// uint256 _amount,
    /// address _l2Receiver
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function bridgehubWithdraw(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external returns (L2TransactionRequestTwoBridgesInner memory request);

    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes memory _transferData) external;

    function finalizeWithdrawal(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external returns (address l1Receiver, uint256 amount);

    function setAssetHandlerAddress(bytes32 _additionalData, address _assetHandlerAddress) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external;

    function nativeTokenVault() external view returns (IL1NativeTokenVault);
}
