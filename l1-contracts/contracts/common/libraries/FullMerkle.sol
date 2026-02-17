// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {Merkle} from "./Merkle.sol";
import {MerkleWrongIndex, MerkleWrongLength, MerkleNothingToProve} from "../L1ContractErrors.sol";

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
     * @dev Returns the root of the tree.
     */
    function root(FullTree storage self) internal view returns (bytes32) {
        return self._nodes[self._height][0];
    }

    /**
     * @dev Returns merkle path for a certain leaf index.
     * @param _index The index of the leaf to calculate proof for.
     */
    function merklePath(FullTree storage self, uint256 _index) internal view returns (bytes32[] memory) {
        if (self._leafNumber == 0) {
            revert MerkleNothingToProve();
        }
        uint256 maxNodeNumber = self._leafNumber - 1;
        if (_index > maxNodeNumber) {
            revert MerkleWrongIndex(_index, maxNodeNumber);
        }
        bytes32[] memory proof = new bytes32[](self._height);
        for (uint256 i = 0; i < self._height; i = i.uncheckedInc()) {
            if (_index % 2 == 0) {
                proof[i] = maxNodeNumber == _index ? self._zeros[i] : self._nodes[i][_index + 1];
            } else {
                proof[i] = self._nodes[i][_index - 1];
            }
            _index /= 2;
            maxNodeNumber /= 2;
        }
        return proof;
    }
}
