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

    function interopRoots(uint256 chainId, uint256 batchNumber) external view returns (StoredInteropRoot memory) {
        return storedInteropRoots[chainId][batchNumber];
    }

    function addInteropRoot(uint256 chainId, uint256 batchNumber, bytes32[] memory sides) external {
        _addInteropRoot(chainId, batchNumber, 0, sides);
    }

    function addInteropRootWithTimestamp(
        uint256 chainId,
        uint256 batchNumber,
        uint256 timestamp,
        bytes32[] memory sides
    ) external {
        _addInteropRoot(chainId, batchNumber, timestamp, sides);
    }

    function _addInteropRoot(uint256 chainId, uint256 batchNumber, uint256 timestamp, bytes32[] memory sides) private {
        emit InteropRootAdded(chainId, batchNumber, timestamp, sides);
        if (sides.length == 1) {
            storedInteropRoots[chainId][batchNumber] = StoredInteropRoot({root: sides[0], timestamp: timestamp});
        }
    }
}
