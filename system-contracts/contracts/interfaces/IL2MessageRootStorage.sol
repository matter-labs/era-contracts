// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IL2MessageRootStorage {
    // function getAggregatedRoot() external view returns (bytes32);
    function addMessageRoot(uint256 chainId, uint256 blockNumber, bytes32 msgRoot) external;

    function msgRoots(uint256 _chainId, uint256 _batchNumber) external view returns (bytes32);
}
