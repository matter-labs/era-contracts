// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";
import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface IL1NativeTokenVault is INativeTokenVaultBase, IL1AssetDeploymentTracker {
    /// @notice The L1Nullifier contract
    function L1_NULLIFIER() external view returns (IL1Nullifier);

    /// @notice The base token asset ID
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Deprecated per-chain balance getter, kept for backwards compatibility only; it will
    /// revert in the next release. Use `bridgedOut` instead.
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Registers ETH token. Should be called once on local/new deployments.
    /// ETH token is expected to have been already initialized in production.
    function registerEthToken() external;

    /// @notice Net amount of the given L1-native asset currently bridged out of L1.
    function bridgedOut(bytes32 _assetId) external view returns (uint256);

    /// @notice Whether the pre-upgrade amount of `_assetId` attributed to `_chainId` has already been
    /// folded into `bridgedOut`.
    function bridgedOutPopulated(uint256 _chainId, bytes32 _assetId) external view returns (bool);

    /// @notice The removed V31 `L1AssetTracker`, which holds the legacy per-chain accounting that
    /// `populateBridgedOut` reads. Zero on ecosystems deployed after the tracker was removed.
    function legacyL1AssetTracker() external view returns (address);

    /// @notice Amount of `_assetId` that the pre-upgrade accounting attributed to `_chainId`.
    /// @param _chainId The chain the legacy amount is attributed to.
    /// @param _assetId The asset to read the legacy amount of.
    /// @return amount The legacy amount, zero for L1 itself.
    function legacyBridgedOutForChain(uint256 _chainId, bytes32 _assetId) external view returns (uint256 amount);

    /// @notice Folds the pre-upgrade amounts that the legacy accounting attributed to `_chainId` into
    /// `bridgedOut`, once per (chain, asset) pair.
    /// See {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
    /// @param _chainId The chain whose legacy amounts are being folded in.
    /// @param _assetIds The L1-native assets to populate; pairs already populated are skipped.
    /// @return populatedAmount The total amount added to `bridgedOut` by this call.
    function populateBridgedOut(
        uint256 _chainId,
        bytes32[] calldata _assetIds
    ) external returns (uint256 populatedAmount);

    event TokenBeaconUpdated(address indexed l2TokenBeacon);

    /// @notice Emitted for every (chain, asset) pair folded into `bridgedOut`, including zero amounts.
    event BridgedOutPopulated(uint256 indexed chainId, bytes32 indexed assetId, uint256 amount);
}
