// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2AssetRouter contract
 */
interface IL2AssetRouter {
    function init_boojum(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _l1AssetRouter,
        address _legacySharedBridge,
        bytes32 _baseTokenAssetId,
        address _aliasedOwner
    ) external;

    function L2_LEGACY_SHARED_BRIDGE() external view returns (address);
}
