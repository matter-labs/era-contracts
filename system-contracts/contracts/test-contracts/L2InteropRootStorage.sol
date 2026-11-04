// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Dev version of L2InteropRootStorage for bootloader test infrastructure.
/// The production contract lives in l1-contracts/contracts/interop/.
contract L2InteropRootStorage {
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => bytes32 interopRoot)) public interopRoots;

    event InteropRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, bytes32[] sides);

    function addInteropRoot(uint256 chainId, uint256 blockOrBatchNumber, bytes32[] calldata sides) external {
        if (sides.length == 1) {
            interopRoots[chainId][blockOrBatchNumber] = sides[0];
        }
        emit InteropRootAdded(chainId, blockOrBatchNumber, sides);
    }
}
