// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title Base Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface INativeTokenVaultBase {
    /// @notice Returns the chain ID of the origin chain for a given asset ID
    function originChainId(bytes32 assetId) external view returns (uint256);

    /// @notice Returns the origin token for a given asset ID
    function originToken(bytes32 assetId) external view returns (address);

    /// @notice Returns the number of bridged tokens.
    function bridgedTokensCount() external view returns (uint256);

    /// @notice Returns the bridged token at index `index`.
    function bridgedTokens(uint256 index) external view returns (bytes32);

    /// @notice Registers a token native to this chain within the NTV.
    /// @dev Deliberately permissionless: bridging native tokens should never need an allowlist.
    function registerToken(address _l1Token) external;

    /// @notice Registers the native token if needed and returns its asset ID.
    function ensureTokenIsRegistered(address _nativeToken) external returns (bytes32);

    /// @notice Used to get the ERC20 data for a token
    function getERC20Getters(address _token, uint256 _originChainId) external view returns (bytes memory);

    /// @notice Used to get the token address of an assetId
    function tokenAddress(bytes32 assetId) external view returns (address);

    /// @notice Used to get the assetId of a token
    function assetId(address token) external view returns (bytes32);

    /// @notice Tries to register the token from the provided `_burnData` as native to this chain,
    /// reverting if it is not possible. Used by the asset router when no handler is registered yet.
    function tryRegisterTokenFromBurnData(bytes calldata _burnData, bytes32 _expectedAssetId) external;

    /// @notice Emitted when a failed/expired atomic-interop transfer is recovered to the depositor.
    event BridgeRecoverFailedTransfer(
        uint256 indexed chainId,
        bytes32 indexed assetId,
        address receiver,
        uint256 amount
    );

    /// @notice Returns a failed/expired atomic-interop transfer's funds to the depositor: unlock for an
    /// origin-native asset, re-mint for a bridged one — reversing the `bridgeBurn` performed at commit.
    /// @dev Callable only by the asset router, which gates it on a proven IMT non-inclusion (timeout).
    /// @param _chainId The chain the asset was being bridged to at burn time (so the chain-balance
    /// accounting reverses correctly).
    /// @param _assetId The asset being recovered.
    /// @param _data Bridge-mint-formatted data whose receiver is the original depositor.
    function bridgeRecoverFailedTransfer(uint256 _chainId, bytes32 _assetId, bytes calldata _data) external payable;
}
