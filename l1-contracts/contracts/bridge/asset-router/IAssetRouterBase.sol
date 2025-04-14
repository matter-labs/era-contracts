// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

/// @dev The encoding version used for legacy txs.
bytes1 constant LEGACY_ENCODING_VERSION = 0x00;

/// @dev The encoding version used for new txs.
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

    event AssetDeploymentTrackerRegistered(
        bytes32 indexed assetId,
        bytes32 indexed additionalData,
        address assetDeploymentTracker
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetHandlerAddress);

    event DepositFinalizedAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    function BRIDGE_HUB() external view returns (IBridgehub);

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterpart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(bytes32 _assetRegistrationData, address _assetHandlerAddress) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @dev We have both the legacy finalizeWithdrawal and the new finalizeDeposit functions,
    /// finalizeDeposit uses the new format. On the L2 we have finalizeDeposit with new and old formats both.
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes memory _transferData) external payable;
}
