// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMTLeaf, IndexedMerkleTree} from "era/common/libraries/IndexedMerkleTree.sol";
import {Merkle} from "era/common/libraries/Merkle.sol";
import {IMT_EMPTY_LEAF_HASH} from "era/common/Config.sol";
import {ImtAppendSlotNotEmpty, ImtLowLeafNotInRoot, ImtPathLength, ImtValueOrder} from "./ZKIPLiteErrors.sol";

/// @notice Verifies on L1 one insertion into a chain's interop commitment tree from roots and paths only: the
/// IndexedMerkleTree.insert steps (low-leaf update, then FullMerkle.pushNewLeaf with its height growth).
library ImtInsertion {
    struct Proof {
        IMTLeaf low;
        uint256 lowIndex;
        bytes32[] lowPath;
        bytes32[] newPath;
    }

    /// @return The root after inserting `_value` into a tree with root `_root` and `_leafCount` leaves.
    function applyInsert(
        bytes32 _root,
        uint256 _leafCount,
        uint256 _value,
        Proof calldata _proof
    ) internal pure returns (bytes32) {
        IMTLeaf memory low = _proof.low;
        require(
            _value != 0 && low.value < _value && (low.nextValue == 0 || _value < low.nextValue),
            ImtValueOrder()
        );
        uint256 heightBefore = height(_leafCount);
        uint256 heightAfter = height(_leafCount + 1);
        require(
            _proof.lowPath.length == heightBefore && _proof.newPath.length == heightAfter && _proof.lowIndex < _leafCount,
            ImtPathLength()
        );
        require(
            Merkle.calculateRoot(_proof.lowPath, _proof.lowIndex, IndexedMerkleTree.hashLeaf(low)) == _root,
            ImtLowLeafNotInRoot()
        );
        bytes32 updated = Merkle.calculateRoot(
            _proof.lowPath,
            _proof.lowIndex,
            IndexedMerkleTree.hashLeaf(IMTLeaf({value: low.value, nextIndex: _leafCount, nextValue: _value}))
        );
        // pushNewLeaf grows the tree when the new index is a power of two: the old root becomes the left child.
        bytes32 grown = heightAfter > heightBefore ? Merkle.efficientHash(updated, zero(heightBefore)) : updated;
        require(
            Merkle.calculateRoot(_proof.newPath, _leafCount, IMT_EMPTY_LEAF_HASH) == grown,
            ImtAppendSlotNotEmpty()
        );
        return
            Merkle.calculateRoot(
                _proof.newPath,
                _leafCount,
                IndexedMerkleTree.hashLeaf(IMTLeaf({value: _value, nextIndex: low.nextIndex, nextValue: low.nextValue}))
            );
    }

    /// @notice FullMerkle height for `_leafCount` leaves.
    function height(uint256 _leafCount) internal pure returns (uint256 h) {
        uint256 maxIndex = _leafCount - 1;
        while (maxIndex != 0) {
            ++h;
            maxIndex >>= 1;
        }
    }

    /// @notice Root of an empty subtree of height `_height`.
    function zero(uint256 _height) internal pure returns (bytes32 z) {
        z = IMT_EMPTY_LEAF_HASH;
        for (uint256 i = 0; i < _height; ++i) {
            z = Merkle.efficientHash(z, z);
        }
    }
}
