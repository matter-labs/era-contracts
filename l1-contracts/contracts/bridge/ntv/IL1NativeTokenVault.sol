// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";
import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";
import {IL1AssetTracker} from "../asset-tracker/IL1AssetTracker.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
// is IL1AssetHandler, IL1BaseTokenAssetHandler {
interface IL1NativeTokenVault is INativeTokenVaultBase, IL1AssetDeploymentTracker {
    /// @notice The L1Nullifier contract
    function L1_NULLIFIER() external view returns (IL1Nullifier);

    /// @notice The base token asset ID
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Returns the total number of specific tokens locked for some chain
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Registers ETH token
    function registerEthToken() external;

    /// Used for V31 migrating token balances to AssetTracker
    function migrateTokenBalanceToAssetTracker(uint256 _chainId, bytes32 _assetId) external returns (uint256);

    function l1AssetTracker() external view returns (IL1AssetTracker);

    event TokenBeaconUpdated(address indexed l2TokenBeacon);
}
