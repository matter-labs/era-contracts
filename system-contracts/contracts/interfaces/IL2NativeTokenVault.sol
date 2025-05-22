// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2NativeTokenVault contract
 */
interface IL2NativeTokenVault {
    function init_boojum(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _bridgedTokenBeacon,
        bool _contractsDeployedAlready,
        address _wethToken,
        bytes32 _baseTokenAssetId
    ) external;

    function tokenAddress(bytes32 _assetId) external view returns (address);
}
