// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {StoredInteropRoot} from "../../common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Dev stand-in for the L2 InteropRootStorage: stores imported interop roots without the
 * bootloader-only access control, mirroring the production `interopRoots` read ABI.
 */
contract DummyL2InteropRootStorage {
    /// @notice Mirrors `L2InteropRootStorage`: `(blockOrBatchNumber, root, timestamp)`
    /// tuples per chain, consulted by message verification and time-sensitive proofs.
    mapping(uint256 chainId => mapping(uint256 batchNumber => StoredInteropRoot)) internal storedInteropRoots;

    event InteropRootAdded(uint256 indexed chainId, uint256 indexed batchNumber, uint256 timestamp, bytes32[] sides);

    /// @notice Mirrors `L2InteropRootStorage.latestInteropRootTimestamp`: the maximum creation
    /// timestamp over all imported roots per chain.
    mapping(uint256 chainId => uint256 timestamp) public latestInteropRootTimestamp;

    function interopRoots(uint256 chainId, uint256 batchNumber) external view returns (StoredInteropRoot memory) {
        return storedInteropRoots[chainId][batchNumber];
    }

    function addInteropRootWithTimestamp(
        uint256 chainId,
        uint256 batchNumber,
        uint256 timestamp,
        bytes32[] memory sides
    ) external {
        emit InteropRootAdded(chainId, batchNumber, timestamp, sides);
        if (sides.length == 1) {
            storedInteropRoots[chainId][batchNumber] = StoredInteropRoot({root: sides[0], timestamp: timestamp});
            if (timestamp > latestInteropRootTimestamp[chainId]) {
                latestInteropRootTimestamp[chainId] = timestamp;
            }
        }
    }
}
