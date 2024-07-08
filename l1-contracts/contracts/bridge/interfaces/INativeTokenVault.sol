// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAssetRouterBase} from "./IAssetRouterBase.sol";

/// @title Base Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface INativeTokenVault {
    event WrappedTokenBeaconUpdated(address wrappedTokenBeacon, bytes32 wrappedTokenProxyBytecodeHash);

    function setWrappedTokenBeacon() external;

    /// @notice The Weth token address
    function WETH_TOKEN() external view returns (address);

    /// @notice The AssetRouter contract
    function ASSET_ROUTER() external view returns (IAssetRouterBase);

    /// @notice Returns the total number of specific tokens locked for some chain
    function chainBalance(uint256 _chainId, address _token) external view returns (uint256);

    /// @notice Returns if the wrapped version of bridged token has been deployed
    function isTokenWrapped(bytes32 assetId) external view returns (bool);

    /// @notice Used to register a token in the vault
    function registerToken(address _l1Token) external;

    /// @notice Used to get the assetId of a token
    function getAssetId(address tokenAddress) external view returns (bytes32);

    /// @notice Used to get the the ERC20 data for a token
    function getERC20Getters(address _token) external view returns (bytes memory);

    /// @notice Used to get the token address of an assetId
    function tokenAddress(bytes32 assetId) external view returns (address);

    /// @notice Used to get the expected wrapped token address corresponding to its native counterpart
    function wrappedTokenAddress(address _nativeToken) external view returns (address);
}
