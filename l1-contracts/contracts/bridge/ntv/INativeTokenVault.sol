// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";

/// @title Base Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface INativeTokenVault {
    event BridgedTokenBeaconUpdated(address bridgedTokenBeacon, bytes32 bridgedTokenProxyBytecodeHash);

    function setBridgedTokenBeacon() external;

    /// @notice The Weth token address
    function WETH_TOKEN() external view returns (address);

    /// @notice The AssetRouter contract
    function ASSET_ROUTER() external view returns (IAssetRouterBase);

    /// @notice The Base token address
    function BASE_TOKEN_ADDRESS() external view returns (address);

    /// @notice Returns the total number of specific tokens locked for some chain
    function chainBalance(uint256 _chainId, address _token) external view returns (uint256);

    /// @notice Returns if the bridged version of bridged token has been deployed
    function isTokenBridged(bytes32 assetId) external view returns (bool);

    /// @notice Used to register a token in the vault
    function registerToken(address _l1Token) external;

    /// @notice Used to get the assetId of a token
    function getAssetId(uint256 _chainId, address _tokenAddress) external view returns (bytes32);

    /// @notice Used to get the the ERC20 data for a token
    function getERC20Getters(address _token) external view returns (bytes memory);

    /// @notice Used to get the token address of an assetId
    function tokenAddress(bytes32 assetId) external view returns (address);

    /// @notice Used to get the expected bridged token address corresponding to its native counterpart
    function bridgedTokenAddress(address _nativeToken) external view returns (address);
}
