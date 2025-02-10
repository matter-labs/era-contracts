// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVault} from "./INativeTokenVault.sol";
import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
// is IL1AssetHandler, IL1BaseTokenAssetHandler {
interface IL1NativeTokenVault is INativeTokenVault, IL1AssetDeploymentTracker {
    /// @notice The L1Nullifier contract
    function L1_NULLIFIER() external view returns (IL1Nullifier);

    /// @notice Returns the total number of specific tokens locked for some chain
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Registers ETH token
    function registerEthToken() external;

    event TokenBeaconUpdated(address indexed l2TokenBeacon);
}
