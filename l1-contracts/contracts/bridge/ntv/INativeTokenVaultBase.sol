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

    /// @notice Registers tokens within the NTV.
    /// @dev The goal is to allow bridging native tokens automatically, by registering them on the fly.
    /// @notice Allows the bridge to register a token address for the vault.
    /// @notice No access control is ok, since the bridging of tokens should be permissionless. This requires permissionless registration.
    function registerToken(address _l1Token) external;

    /// @notice Ensures that the native token is registered with the NTV.
    /// @dev This function is used to ensure that the token is registered with the NTV.
    function ensureTokenIsRegistered(address _nativeToken) external returns (bytes32);

    /// @notice Used to get the the ERC20 data for a token
    function getERC20Getters(address _token, uint256 _originChainId) external view returns (bytes memory);

    /// @notice Used to get the token address of an assetId
    function tokenAddress(bytes32 assetId) external view returns (address);

    /// @notice Used to get the assetId of a token
    function assetId(address token) external view returns (bytes32);

    /// @notice Tries to register a token from the provided `_burnData` and reverts if it is not possible.
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

    /// @notice Refunds a timed-out atomic-interop base-token value leg that was funded via
    /// `bridgehubDepositBaseToken` (the different-base-token path): unlock for an origin-native asset,
    /// re-mint for a bridged one, reversing the `bridgeBurn` performed at send time.
    /// @dev Like {bridgeRecoverFailedTransfer} but takes the receiver/amount directly, since the base-token
    /// deposit discarded its bridge-mint data. The asset is already registered on this chain (it was
    /// burned from the depositor), so no origin-token/metadata is needed. Callable only by the asset router.
    /// @param _chainId The chain the asset was being bridged to at burn time.
    /// @param _assetId The (destination base token) asset being recovered.
    /// @param _receiver The original depositor to refund.
    /// @param _amount The amount to recover.
    function bridgeRecoverBaseToken(uint256 _chainId, bytes32 _assetId, address _receiver, uint256 _amount) external;
}
