// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IMessageRoot {
    /// @notice The aggregated root of the batches from different chains.
    /// @return aggregatedRoot of the batches from different chains.
    function getAggregatedRoot() external view returns (bytes32 aggregatedRoot);
}
