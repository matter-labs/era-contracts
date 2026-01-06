// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {Merkle} from "./Merkle.sol";
import {MerkleWrongIndex, MerkleWrongLength} from "../L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library FullMerkleMemory {
    using UncheckedMath for uint256;

    struct FullTree {
        uint256 _height;
        uint256 _leafNumber;
        uint256 _nodesLengthMemory;
        uint256 _zerosLengthMemory;
        bytes32[][] _nodes;
        bytes32[] _zeros;
    }

    error InvalidMaxLeafNumber(uint256 _maxLeafNumber);

    function createTree(FullTree memory self, uint256 _maxLeafNumber) internal view {
        if (_maxLeafNumber == 0) {
            revert InvalidMaxLeafNumber(0);
        }

        uint256 height = 0;
        uint256 tempLeafNumber = _maxLeafNumber;

        while (tempLeafNumber > 1) {
            ++height;
            tempLeafNumber = (tempLeafNumber + 1) / 2;
        }

        bytes32[][] memory nodes = new bytes32[][](height + 1);
        nodes[0] = new bytes32[](_maxLeafNumber);

        uint256 currentLevelSize = _maxLeafNumber;
        for (uint256 i = 1; i <= height; ++i) {
            currentLevelSize = (currentLevelSize + 1) / 2;
            nodes[i] = new bytes32[](currentLevelSize);
        }

        bytes32[] memory zeros = new bytes32[](height + 1);

        self._zeros = zeros;
        self._nodes = nodes;
        self._height = 0; // Start with height 0 like FullMerkle
        self._leafNumber = 0;
        self._nodesLengthMemory = height + 1;
        self._zerosLengthMemory = height + 1;
    }

    /**
     * @dev Initialize a {FullTree} using {Merkle.efficientHash} to hash internal nodes.
     * The capacity of the tree (i.e. number of leaves) is set to `2**levels`.
     *
     * IMPORTANT: The zero value should be carefully chosen since it will be stored in the tree representing
     * empty leaves. It should be a value that is not expected to be part of the tree.
     * @param zero The zero value to be used in the tree.
     */
    function setup(FullTree memory self, bytes32 zero) internal view returns (bytes32 initialRoot) {
        self._zeros[0] = zero;
        bytes32 currentZero = zero;

        // Pre-compute zeros for all possible heights
        uint256 maxPossibleHeight = self._nodes.length - 1;
        for (uint256 i = 1; i <= maxPossibleHeight; ++i) {
            currentZero = Merkle.efficientHash(currentZero, currentZero);
            self._zeros[i] = currentZero;
        }

        self._zerosLengthMemory = maxPossibleHeight + 1;
        self._nodesLengthMemory = maxPossibleHeight + 1;

        // Don't pre-set root for empty tree to match FullMerkle behavior
        return zero;
    }

    /**
     * @dev Push a new leaf to the tree.
     * @param _leaf The leaf to be added to the tree.
     */
    function pushNewLeaf(FullTree memory self, bytes32 _leaf) internal view returns (bytes32 newRoot) {
        // Check capacity before proceeding using natural array bounds
        if (self._leafNumber >= self._nodes[0].length) {
            revert MerkleWrongIndex(self._leafNumber, self._nodes[0].length);
        }

        // solhint-disable-next-line gas-increment-by-one
        uint256 index = self._leafNumber++;

        if (index == 1 << self._height) {
            uint256 newHeight = self._height.uncheckedInc();
            self._height = newHeight;
        }

        if (index != 0) {
            uint256 oldMaxNodeNumber = index - 1;
            uint256 maxNodeNumber = index;

            for (uint256 i = 1; i <= self._height; i = i.uncheckedInc()) {
                maxNodeNumber /= 2;
                oldMaxNodeNumber /= 2;

                if (oldMaxNodeNumber == maxNodeNumber) {
                    break;
                }

                if (self._nodes[i].length == 0) {
                    self._nodes[i] = new bytes32[](self._nodes[i - 1].length / 2 + 1);
                }

                self._nodes[i][maxNodeNumber] = self._zeros[i];
            }
        }
        return updateLeaf(self, index, _leaf);
    }

    /**
     * @dev Update a leaf at index in the tree.
     * @param _index The index of the leaf to be updated.
     * @param _itemHash The new hash of the leaf.
     */
    function updateLeaf(FullTree memory self, uint256 _index, bytes32 _itemHash) internal view returns (bytes32) {
        uint256 maxNodeNumber = self._leafNumber - 1;
        if (_index > maxNodeNumber) {
            revert MerkleWrongIndex(_index, maxNodeNumber);
        }

        self._nodes[0][_index] = _itemHash;
        bytes32 currentHash = _itemHash;
        for (uint256 i; i < self._height; i = i.uncheckedInc()) {
            if (_index % 2 == 0) {
                currentHash = Merkle.efficientHash(
                    currentHash,
                    maxNodeNumber == _index ? self._zeros[i] : self._nodes[i][_index + 1]
                );
            } else {
                currentHash = Merkle.efficientHash(self._nodes[i][_index - 1], currentHash);
            }
            _index /= 2;
            maxNodeNumber /= 2;

            if (self._nodes[i + 1].length == 0) {
                self._nodes[i + 1] = new bytes32[](self._nodes[i].length / 2 + 1);
            }

            self._nodes[i + 1][_index] = currentHash;
        }
        return currentHash;
    }

    /**
     * @dev Updated all leaves in the tree.
     * @param _newLeaves The new leaves to be added to the tree.
     */
    function updateAllLeaves(FullTree memory self, bytes32[] memory _newLeaves) internal view returns (bytes32) {
        if (_newLeaves.length != self._leafNumber) {
            revert MerkleWrongLength(_newLeaves.length, self._leafNumber);
        }
        return updateAllNodesAtHeight(self, 0, _newLeaves);
    }

    /**
     * @dev Update all nodes at a certain height in the tree.
     * @param _height The height of the nodes to be updated.
     * @param _newNodes The new nodes to be added to the tree.
     */
    function updateAllNodesAtHeight(
        FullTree memory self,
        uint256 _height,
        bytes32[] memory _newNodes
    ) internal view returns (bytes32) {
        if (_height == self._height) {
            self._nodes[_height][0] = _newNodes[0];
            return _newNodes[0];
        }

        uint256 newRowLength = (_newNodes.length + 1) / 2;
        bytes32[] memory _newRow = new bytes32[](newRowLength);

        uint256 length = _newNodes.length;
        for (uint256 i; i < length; i = i.uncheckedAdd(2)) {
            self._nodes[_height][i] = _newNodes[i];
            if (i + 1 < length) {
                self._nodes[_height][i + 1] = _newNodes[i + 1];
                _newRow[i / 2] = Merkle.efficientHash(_newNodes[i], _newNodes[i + 1]);
            } else {
                // Handle odd number of nodes by hashing the last node with zero
                _newRow[i / 2] = Merkle.efficientHash(_newNodes[i], self._zeros[_height]);
            }
        }
        return updateAllNodesAtHeight(self, _height + 1, _newRow);
    }

    /**
     * @dev Returns the root of the tree.
     */
    function root(FullTree memory self) internal view returns (bytes32) {
        // Return zero value for empty trees like FullMerkle
        if (self._leafNumber == 0) {
            return self._zeros[0];
        }

        // For non-empty trees, return the actual root
        if (self._height == 0 && self._leafNumber == 1) {
            return self._nodes[0][0]; // Single leaf case
        }

        return self._nodes[self._height][0];
    }
}
