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

    function setLegacyTokenAssetId(address _l2TokenAddress) external;
}
