// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library Merkle {
    using UncheckedMath for uint256;

    /// @dev Calculate Merkle root by the provided Merkle proof.
    /// NOTE: When using this function, check that the _path length is equal to the tree height to prevent shorter/longer paths attack
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
        require(pathLength > 0, "xc");
        require(pathLength < 256, "bt");
        require(_index < (1 << pathLength), "px");

        bytes32 currentHash = _itemHash;
        for (uint256 i; i < pathLength; i = i.uncheckedInc()) {
            currentHash = (_index % 2 == 0)
                ? _efficientHash(currentHash, _path[i])
                : _efficientHash(_path[i], currentHash);
            _index /= 2;
        }

        return currentHash;
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
