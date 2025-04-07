// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {MerklePathEmpty, MerklePathOutOfBounds, MerkleIndexOutOfBounds, MerklePathLengthMismatch, MerkleNothingToProve, MerkleIndexOrHeightMismatch} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library Merkle {
    using UncheckedMath for uint256;

    /// @dev Calculate Merkle root by the provided Merkle proof.
    /// NOTE: When using this function, check that the _path length is equal to the tree height to prevent shorter/longer paths attack
    /// however, for chains settling on GW the proof includes the GW proof, so the path increases. See Mailbox for more details.
    /// @param _path Merkle path from the leaf to the root
    /// @param _index Leaf index in the tree
    /// @param _itemHash Hash of leaf content
    /// @return The Merkle root
    function calculateRoot(
        bytes32[] calldata _path,
        uint256 _index,
        bytes32 _itemHash
    ) internal pure returns (bytes32) {
        uint256 pathLength = _path.length;
        _validatePathLengthForSingleProof(_index, pathLength);

        bytes32 currentHash = _itemHash;
        for (uint256 i; i < pathLength; i = i.uncheckedInc()) {
            currentHash = (_index % 2 == 0)
                ? efficientHash(currentHash, _path[i])
                : efficientHash(_path[i], currentHash);
            _index /= 2;
        }

        return currentHash;
    }

    /// @dev Calculate Merkle root by the provided Merkle proof.
    /// @dev NOTE: When using this function, check that the _path length is appropriate to prevent shorter/longer paths attack
    /// @param _path Merkle path from the leaf to the root
    /// @param _index Leaf index in the tree.
    /// @dev NOTE the tree can be joined. In this case the second tree's leaves indexes increase by the number of leaves in the first tree.
    /// @param _itemHash Hash of leaf content
    /// @return The Merkle root
    function calculateRootMemory(
        bytes32[] memory _path,
        uint256 _index,
        bytes32 _itemHash
    ) internal pure returns (bytes32) {
        uint256 pathLength = _path.length;
        _validatePathLengthForSingleProof(_index, pathLength);

        bytes32 currentHash = _itemHash;
        for (uint256 i; i < pathLength; i = i.uncheckedInc()) {
            currentHash = (_index % 2 == 0)
                ? efficientHash(currentHash, _path[i])
                : efficientHash(_path[i], currentHash);
            _index /= 2;
        }

        return currentHash;
    }

    /// @dev Calculate Merkle root by the provided Merkle proof for a range of elements
    /// NOTE: When using this function, check that the _startPath and _endPath lengths are equal to the tree height to prevent shorter/longer paths attack
    /// @param _startPath Merkle path from the first element of the range to the root
    /// @param _endPath Merkle path from the last element of the range to the root
    /// @param _startIndex Index of the first element of the range in the tree
    /// @param _itemHashes Hashes of the elements in the range
    /// @return The Merkle root
    function calculateRootPaths(
        bytes32[] memory _startPath,
        bytes32[] memory _endPath,
        uint256 _startIndex,
        bytes32[] memory _itemHashes
    ) internal pure returns (bytes32) {
        uint256 pathLength = _startPath.length;
        if (pathLength != _endPath.length) {
            revert MerklePathLengthMismatch(pathLength, _endPath.length);
        }
        if (pathLength >= 256) {
            revert MerklePathOutOfBounds();
        }
        uint256 levelLen = _itemHashes.length;
        // Edge case: we want to be able to prove an element in a single-node tree.
        if (pathLength == 0 && (_startIndex != 0 || levelLen != 1)) {
            revert MerklePathEmpty();
        }
        if (levelLen == 0) {
            revert MerkleNothingToProve();
        }
        if (_startIndex + levelLen > (1 << pathLength)) {
            revert MerkleIndexOrHeightMismatch();
        }
        bytes32[] memory itemHashes = _itemHashes;

        for (uint256 level; level < pathLength; level = level.uncheckedInc()) {
            uint256 parity = _startIndex % 2;
            // We get an extra element on the next level if on the current level elements either
            // start on an odd index (`parity == 1`) or end on an even index (`levelLen % 2 == 1`)
            uint256 nextLevelLen = levelLen / 2 + (parity | (levelLen % 2));
            for (uint256 i; i < nextLevelLen; i = i.uncheckedInc()) {
                bytes32 lhs = (i == 0 && parity == 1) ? _startPath[level] : itemHashes[2 * i - parity];
                bytes32 rhs = (i == nextLevelLen - 1 && (levelLen - parity) % 2 == 1)
                    ? _endPath[level]
                    : itemHashes[2 * i + 1 - parity];
                itemHashes[i] = efficientHash(lhs, rhs);
            }
            levelLen = nextLevelLen;
            _startIndex /= 2;
        }

        return itemHashes[0];
    }

    /// @dev Keccak hash of the concatenation of two 32-byte words
    function efficientHash(bytes32 _lhs, bytes32 _rhs) internal pure returns (bytes32 result) {
        assembly {
            mstore(0x00, _lhs)
            mstore(0x20, _rhs)
            result := keccak256(0x00, 0x40)
        }
    }

    function _validatePathLengthForSingleProof(uint256 _index, uint256 _pathLength) private pure {
        if (_pathLength >= 256) {
            revert MerklePathOutOfBounds();
        }
        if (_index >= (1 << _pathLength)) {
            revert MerkleIndexOutOfBounds();
        }
    }
}
