// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {Merkle} from "./Merkle.sol";
import {MerkleWrongIndex, MerkleWrongLength} from "../L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library FullMerkle {
    using UncheckedMath for uint256;

    struct FullTree {
        uint256 _height;
        uint256 _leafNumber;
        bytes32[][] _nodes;
        bytes32[] _zeros;
    }

    /**
     * @dev Initialize a {FullTree} using {Merkle.efficientHash} to hash internal nodes.
     * The capacity of the tree (i.e. number of leaves) is set to `2**levels`.
     *
     * IMPORTANT: The zero value should be carefully chosen since it will be stored in the tree representing
     * empty leaves. It should be a value that is not expected to be part of the tree.
     * @param zero The zero value to be used in the tree.
     */
    function setup(FullTree storage self, bytes32 zero) internal returns (bytes32 initialRoot) {
        // Store depth in the dynamic array
        self._zeros.push(zero);
        self._nodes.push([zero]);

        return zero;
    }

    /**
     * @dev Push a new leaf to the tree.
     * @param _leaf The leaf to be added to the tree.
     */
    function pushNewLeaf(FullTree storage self, bytes32 _leaf) internal returns (bytes32 newRoot) {
        // solhint-disable-next-line gas-increment-by-one
        uint256 index = self._leafNumber++;

        if (index == 1 << self._height) {
            uint256 newHeight = self._height.uncheckedInc();
            self._height = newHeight;
            bytes32 topZero = self._zeros[newHeight - 1];
            bytes32 newZero = Merkle.efficientHash(topZero, topZero);
            self._zeros.push(newZero);
            self._nodes.push([newZero]);
        }
        if (index != 0) {
            uint256 oldMaxNodeNumber = index - 1;
            uint256 maxNodeNumber = index;
            for (uint256 i; i < self._height; i = i.uncheckedInc()) {
                if (oldMaxNodeNumber == maxNodeNumber) {
                    break;
                }
                self._nodes[i].push(self._zeros[i]);
                maxNodeNumber /= 2;
                oldMaxNodeNumber /= 2;
            }
        }
        return updateLeaf(self, index, _leaf);
    }

    /**
     * @dev Update a leaf at index in the tree.
     * @param _index The index of the leaf to be updated.
     * @param _itemHash The new hash of the leaf.
     */
    function updateLeaf(FullTree storage self, uint256 _index, bytes32 _itemHash) internal returns (bytes32) {
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
            self._nodes[i + 1][_index] = currentHash;
        }
        return currentHash;
    }

    /**
     * @dev Updated all leaves in the tree.
     * @param _newLeaves The new leaves to be added to the tree.
     */
    function updateAllLeaves(FullTree storage self, bytes32[] memory _newLeaves) internal returns (bytes32) {
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
        FullTree storage self,
        uint256 _height,
        bytes32[] memory _newNodes
    ) internal returns (bytes32) {
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
    function root(FullTree storage self) internal view returns (bytes32) {
        return self._nodes[self._height][0];
    }
}
