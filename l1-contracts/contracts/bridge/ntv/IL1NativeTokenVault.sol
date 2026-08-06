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

    /// @notice Whether the pre-upgrade amount of `_assetId` has already been folded into `bridgedOut`.
    function bridgedOutPopulated(bytes32 _assetId) external view returns (bool);

    /// @notice The removed V31 `L1AssetTracker`, which holds the legacy per-chain accounting that
    /// `populateBridgedOut` reads. Zero on ecosystems deployed after the tracker was removed.
    function legacyL1AssetTracker() external view returns (address);

    /// @notice Net amount of `_assetId` that the pre-upgrade accounting had bridged out of L1.
    /// @dev Reverts with `AssetNotNativeToL1` unless the asset's origin chain is L1: the legacy sources only
    /// answer this question for L1-native assets.
    /// @param _assetId The asset to read the legacy amount of.
    /// @return amount The legacy amount; zero on an ecosystem with no legacy accounting left.
    function legacyBridgedOut(bytes32 _assetId) external view returns (uint256 amount);

    /// @notice Folds the pre-upgrade amount the legacy accounting recorded for each asset into
    /// `bridgedOut`, once per asset.
    /// See {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
    /// @param _assetIds The L1-native assets to populate; assets already populated are skipped.
    /// @return populatedAmounts Per entry of `_assetIds`, the amount added to that asset's
    /// `bridgedOut`; zero for assets that were skipped or had no legacy amount.
    function populateBridgedOut(bytes32[] calldata _assetIds) external returns (uint256[] memory populatedAmounts);

    /// @notice Whether the pre-upgrade amount of `_assetId` has already been folded into `bridgedOut`.
    function bridgedOutPopulated(bytes32 _assetId) external view returns (bool);

    /// @notice The removed V31 `L1AssetTracker`, which holds the legacy per-chain accounting that
    /// `populateBridgedOut` reads. Zero on ecosystems deployed after the tracker was removed.
    function legacyL1AssetTracker() external view returns (address);

    /// @notice Net amount of `_assetId` that the pre-upgrade accounting had bridged out of L1.
    /// @dev Reverts with `AssetNotNativeToL1` unless the asset's origin chain is L1: the legacy sources only
    /// answer this question for L1-native assets.
    /// @param _assetId The asset to read the legacy amount of.
    /// @return amount The legacy amount; zero on an ecosystem with no legacy accounting left.
    function legacyBridgedOut(bytes32 _assetId) external view returns (uint256 amount);

    /// @notice Folds the pre-upgrade amount the legacy accounting recorded for each asset into
    /// `bridgedOut`, once per asset.
    /// See {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
    /// @param _assetIds The L1-native assets to populate; assets already populated are skipped.
    /// @return populatedAmounts Per entry of `_assetIds`, the amount added to that asset's
    /// `bridgedOut`; zero for assets that were skipped or had no legacy amount.
    function populateBridgedOut(bytes32[] calldata _assetIds) external returns (uint256[] memory populatedAmounts);

    event TokenBeaconUpdated(address indexed l2TokenBeacon);

    /// @notice Emitted for every asset folded into `bridgedOut`, including zero amounts.
    event BridgedOutPopulated(bytes32 indexed assetId, uint256 amount);
}
