// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IL1AssetHandler} from "./IL1AssetHandler.sol";
import {IL1BaseTokenAssetHandler} from "./IL1BaseTokenAssetHandler.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface IL1NativeTokenVault is IL1AssetHandler, IL1BaseTokenAssetHandler {
    /// @notice The L1AssetRouter contract
    function L1_SHARED_BRIDGE() external view returns (IL1AssetRouter);

    /// @notice The weth contract
    function L1_WETH_TOKEN() external view returns (address);

    /// @notice Used to register a token in the vault
    function registerToken(address _l1Token) external;

    /// @notice Used to get the ERC20 data for a token
    function getERC20Getters(address _token) external view returns (bytes memory);

    /// @notice Used the get token balance for specific ZK chain in shared bridge
    function chainBalance(uint256 _chainId, address _l1Token) external view returns (uint256);

    /// @dev Shows the assetId for a given chain and token address
    function getAssetId(uint256 _chainId, address _l1Token) external pure returns (bytes32);
}
