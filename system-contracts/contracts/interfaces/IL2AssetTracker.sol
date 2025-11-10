// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2AssetTracker contract
 */
interface IL2AssetTracker {
    function setAddresses(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external;

    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external;

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _amount) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;
}
