// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2AssetTracker contract
 */
interface IL2AssetTracker {
    function setAddresses(
        uint256 _l1ChainId,
        address _bridgeHub,
        address,
        address _nativeTokenVault,
        address _messageRoot
    ) external;

    function handleInitiateBaseTokenBridgingOnL2() external view;

    function handleFinalizeBaseTokenBridgingOnL2() external;
}
