// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {Arrays} from "./openzeppelin/Arrays.sol";
// import "forge-std/console.sol";

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
     * @dev Initialize a {Bytes32PushTree} using {Hashes-Keccak256} to hash internal nodes.
     * The capacity of the tree (i.e. number of leaves) is set to `2**levels`.
     *
     * Calling this function on MerkleTree that was already setup and used will reset it to a blank state.
     *
     * IMPORTANT: The zero value should be carefully chosen since it will be stored in the tree representing
     * empty leaves. It should be a value that is not expected to be part of the tree.
     */
    function setup(FullTree storage self, bytes32 zero) internal returns (bytes32 initialRoot) {
        // Store depth in the dynamic array
        Arrays.unsafeSetLength(self._zeros, 1);
        Arrays.unsafeAccess(self._zeros, 0).value = zero;
        self._nodes.push([zero]);

        return zero;
    }

    function pushNewLeaf(FullTree storage self, bytes32 _leaf) internal returns (bytes32 newRoot) {
        // solhint-disable-next-line gas-increment-by-one
        uint256 index = self._leafNumber++;

        if ((index == 1 << self._height)) {
            uint256 newHeight = self._height.uncheckedInc();
            self._height = newHeight;
            bytes32 topZero = self._zeros[newHeight - 1];
            bytes32 newZero = _efficientHash(topZero, topZero);
            self._zeros.push(newZero);
            // uint256 length = self._zeros.length;
            // console.log("newZero", uint256(newZero), length);
            self._nodes.push([newZero]);
        }
        if (index != 0) {
            uint256 oldMaxNodeNumber = index - 1;
            uint256 maxNodeNumber = index;
            for (uint256 i; i < self._height; i = i.uncheckedInc()) {
                self._nodes[i].push(self._zeros[i]);
                if (oldMaxNodeNumber == maxNodeNumber) {
                    break;
                }
                maxNodeNumber /= 2;
                oldMaxNodeNumber /= 2;
            }
        }
        return updateLeaf(self, index, _leaf);
    }

    function updateLeaf(FullTree storage self, uint256 _index, bytes32 _itemHash) internal returns (bytes32) {
        // solhint-disable-next-line gas-custom-errors
        uint256 maxNodeNumber = self._leafNumber - 1;
        require(_index <= maxNodeNumber, "FMT, wrong index");
        self._nodes[0][_index] = _itemHash;
        bytes32 currentHash = _itemHash;
        for (uint256 i; i < self._height; i = i.uncheckedInc()) {
            if (_index % 2 == 0) {
                currentHash = _efficientHash(
                    currentHash,
                    maxNodeNumber == _index ? self._zeros[i] : self._nodes[i][_index + 1]
                );
            } else {
                currentHash = _efficientHash(self._nodes[i][_index - 1], currentHash);
            }
            _index /= 2;
            maxNodeNumber /= 2;
            self._nodes[i + 1][_index] = currentHash;
        }
        return currentHash;
    }

    function updateAllLeaves(FullTree storage self, bytes32[] memory _newLeaves) internal returns (bytes32) {
        // solhint-disable-next-line gas-custom-errors
        require(_newLeaves.length == self._leafNumber, "FMT, wrong length");
        return updateAllNodesAtHeight(self, 0, _newLeaves);
    }

    function updateAllNodesAtHeight(
        FullTree storage self,
        uint256 _height,
        bytes32[] memory _newNodes
    ) internal returns (bytes32) {
        if (_height == self._height) {
            self._nodes[_height][0] = _newNodes[0];
            return _newNodes[0];
        }
        bytes32[] memory _newRow;
        uint256 length = _newNodes.length;
        for (uint256 i; i < length; i = i.uncheckedAdd(2)) {
            self._nodes[_height][i] = _newNodes[i];
            self._nodes[_height][i + 1] = _newNodes[i + 1];
            _newRow[i / 2] = _efficientHash(_newNodes[i], _newNodes[i + 1]);
        }
        return updateAllNodesAtHeight(self, _height + 1, _newRow);
    }

    /// @dev Keccak hash of the concatenation of two 32-byte words
    function _efficientHash(bytes32 _lhs, bytes32 _rhs) private pure returns (bytes32 result) {
        assembly {
            mstore(0x00, _lhs)
            mstore(0x20, _rhs)
            result := keccak256(0x00, 0x40)
        }
    }

    function root(FullTree storage self) internal view returns (bytes32) {
        return self._nodes[self._height][0];
    }
}
