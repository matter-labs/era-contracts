// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the GWAssetTracker contract
 */
interface IGWAssetTracker {
    function setAddresses(uint256 _l1ChainId) external;
}
