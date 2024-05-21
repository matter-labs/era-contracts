// SPDX-License-Identifier: Apache-2.0
// Adapted from Substrate's binary_merkle_tree (last updated v 15.0.0) (https://docs.rs/binary-merkle-tree/latest/binary_merkle_tree/)

pragma solidity ^0.8.0;

/**
 * @dev This function deals with verification of Merkle Tree proofs
 *      Specifically for Substrate's binary-merkle-tree v15.0.0
 */
library Merkle {
    /// @notice Guard error for empty proofs
    error IndexOutOfBounds();

    function verifyProofKeccak(
        bytes32 root,
        bytes32[] calldata proof,
        uint256 numberOfLeaves,
        uint256 leafIndex,
        bytes32 leaf
    ) internal pure returns (bool) {
        if (leafIndex >= numberOfLeaves) {
            revert IndexOutOfBounds();
        }

        bytes32 computedHash = keccak256(abi.encodePacked(leaf));

        uint256 position = leafIndex;
        uint256 width = numberOfLeaves;

        uint256 limit = proof.length;
        for (uint256 i; i < limit; ) {
            bytes32 proofElement = proof[i];

            if (position % 2 == 1 || position + 1 == width) {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            } else {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            }

            position /= 2;
            width = (width - 1) / 2 + 1;

            unchecked {
                ++i;
            }
        }

        return computedHash == root;
    }
}
