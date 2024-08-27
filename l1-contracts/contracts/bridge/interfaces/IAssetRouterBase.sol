// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {INativeTokenVault} from "./INativeTokenVault.sol";

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
        bytes32 assetDataHash // Todo: What's the point of emitting hash?
    );

    event DepositFinalizedAssetRouter(uint256 chainId, address receiver, bytes32 indexed assetId, uint256 amount); // why hash? shall we make it similar to WithdrawalFinalizedAssetRouter?

    event AssetHandlerRegistered(
        bytes32 indexed assetId,
        address indexed assetHandlerAddress,
        bytes32 assetData,
        address assetDeploymentTracker
    );

    function BRIDGE_HUB() external view returns (IBridgehub);
    function BASE_TOKEN_ADDRESS() external view returns (address);

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) external payable;

    /// @dev Data has the following abi encoding for legacy deposits:
    /// address _l1Token,
    /// uint256 _amount,
    /// address _l2Receiver
    /// for new deposits:
    /// bytes32 _assetId,
    /// bytes _transferData
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes memory _transferData
    ) external returns (address l1Receiver, uint256 amount);

    function setAssetHandlerAddressThisChain(bytes32 _additionalData, address _assetHandlerAddress) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function setNativeTokenVault(INativeTokenVault _nativeTokenVault) external;

    function nativeTokenVault() external view returns (INativeTokenVault);

    function getDepositL2Calldata(
        uint256 _chainId,
        address _l1Sender,
        bytes32 _assetId,
        bytes memory _transferData
    ) external view returns (bytes memory);
}
