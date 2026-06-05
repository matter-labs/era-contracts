// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMerkle} from "contracts/common/libraries/FullMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {FlowLeg, IMT_EMPTY_LEAF, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";

/// @notice A {FullMerkle}-backed tree used by tests to generate Merkle paths. {FullMerkle} and
/// {DynamicIncrementalMerkle} produce identical roots for the same leaves + zero value, so a path
/// generated here verifies against an {L2InteropCommitmentTree} (or the global tree) root.
contract FullMerkleWrapper {
    using FullMerkle for FullMerkle.FullTree;

    FullMerkle.FullTree internal _tree;

    constructor() {
        _tree.setup(IMT_EMPTY_LEAF);
    }

    function push(bytes32 _leaf) external returns (bytes32) {
        return _tree.pushNewLeaf(_leaf);
    }

    function updateLeaf(uint256 _index, bytes32 _leaf) external returns (bytes32) {
        return _tree.updateLeaf(_index, _leaf);
    }

    function root() external view returns (bytes32) {
        return _tree.root();
    }

    function path(uint256 _index) external view returns (bytes32[] memory) {
        return _tree.merklePath(_index);
    }
}

/// @notice Calldata wrapper so tests can verify a Merkle path the same way the proof library does.
contract MerkleCalldataWrapper {
    function calcRoot(bytes32[] calldata _path, uint256 _index, bytes32 _leaf) external pure returns (bytes32) {
        return Merkle.calculateRoot(_path, _index, _leaf);
    }
}

/// @notice Shared pure helpers mirroring the off-chain coordinator / proof library.
library AtomicInteropTestUtils {
    function commitLeaf(bytes32 _flowId, bytes32 _specHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash));
    }

    function globalLeaf(uint256 _chainId, bytes32 _chainImtRoot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainImtRoot, _chainId));
    }

    function specHashOf(FlowLeg memory _leg) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leg));
    }

    /// @notice Computes flowId exactly as {AtomicFlowEscrow}. `_specHashes` and `_chainIds` must be
    /// strictly ascending.
    function computeFlowId(
        bytes32[] memory _specHashes,
        uint256[] memory _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_specHashes, _chainIds, _deadline));
    }
}
