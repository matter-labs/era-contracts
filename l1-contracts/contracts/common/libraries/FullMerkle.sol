// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";

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

    function updateLeaf(FullTree storage self, uint256 _index, bytes32 _itemHash) internal returns (bytes32) {
        bytes32 currentHash = _itemHash;
        for (uint256 i; i < self._height; i = i.uncheckedInc()) {
            if (_index % 2 == 0) {
                currentHash = _efficientHash(currentHash, self._nodes[i][_index + 1]);
            } else {
                currentHash = _efficientHash(self._nodes[i][_index - 1], currentHash);
            }
            _index /= 2;
            self._nodes[i + 1][_index] = currentHash;
        }
        return currentHash;
    }

    function updateAllLeaves(FullTree storage self, bytes32[] memory _newLeaves) internal returns (bytes32) {
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
        for (uint256 i; i < _newNodes.length; i = i.uncheckedAdd(2)) {
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
}
