// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";

/// @dev The encoding version used for new txs.
bytes1 constant LEGACY_ENCODING_VERSION = 0x00;

/// @dev The encoding version used for legacy txs.
bytes1 constant NEW_ENCODING_VERSION = 0x01;

/// @dev The encoding version used for txs that set the asset handler on the counterpart contract.
bytes1 constant SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION = 0x02;

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

    // event DepositFinalizedAssetRouter(uint256 chainId, address receiver, bytes32 indexed assetId, uint256 amount); // why hash? shall we make it similar to WithdrawalFinalizedAssetRouter?

    event AssetHandlerRegisteredInitial(
        bytes32 indexed assetId,
        address indexed assetHandlerAddress,
        bytes32 indexed additionalData,
        address assetDeploymentTracker
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetAddress);

    function BRIDGE_HUB() external view returns (IBridgehub);
    function BASE_TOKEN_ADDRESS() external view returns (address);

    function setAssetHandlerAddressThisChain(bytes32 _additionalData, address _assetHandlerAddress) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function nativeTokenVault() external view returns (INativeTokenVault);

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(uint256 _originChainId, bytes32 _assetId, address _assetAddress) external;

    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes memory _transferData) external;
}
