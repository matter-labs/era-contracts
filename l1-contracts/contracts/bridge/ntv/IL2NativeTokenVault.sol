// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2NativeTokenVault is INativeTokenVaultBase {
    event FinalizeDeposit(
        address indexed l1Sender,
        address indexed l2Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event WithdrawalInitiated(
        address indexed l2Sender,
        address indexed l1Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event L2TokenBeaconUpdated(address indexed l2TokenBeacon, bytes32 indexed l2TokenProxyBytecodeHash);

    function l2TokenAddress(address _l1Token) external view returns (address);

    /// @notice The base token asset ID
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice The wrapped base token (WETH) address
    function WETH_TOKEN() external view returns (address);

    /// @notice The chain ID of L1, set during genesis or upgrade.
    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Eagerly initializes the chain-local bookkeeping for a legacy non-base token.
    /// @dev The base token is rejected: its baseline is recorded by `L2AssetTracker.trackBaseToken`
    /// during the upgrade/genesis, and it has no vault escrow to seed.
    function trackLegacyToken(bytes32 _assetId) external;

    function setLegacyTokenAssetId(address _l2TokenAddress) external;
}
