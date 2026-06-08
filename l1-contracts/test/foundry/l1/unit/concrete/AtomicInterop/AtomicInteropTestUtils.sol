// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMerkle} from "contracts/common/libraries/FullMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {
    SendSpec,
    IndexedLeaf,
    IMT_EMPTY_LEAF,
    ATOMIC_COMMIT_LEAF_TAG
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";

/// @notice A {FullMerkle}-backed tree used by tests to generate Merkle paths. {FullMerkle} and the
/// chain IMT / global tree produce identical roots/paths for the same leaf hashes + zero value.
contract FullMerkleWrapper {
    using FullMerkle for FullMerkle.FullTree;

    FullMerkle.FullTree internal _tree;

    constructor() {
        _tree.setup(IMT_EMPTY_LEAF);
    }

    function push(bytes32 _leaf) external returns (bytes32) {
        return _tree.pushNewLeaf(_leaf);
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

/// @notice Mirrors an on-chain {IL2InteropCommitmentTree} into a {FullMerkleWrapper} so tests can
/// produce inclusion / non-inclusion Merkle paths and compute low-nullifier indices.
contract IndexedImtProver {
    function mirror(IL2InteropCommitmentTree _tree) public returns (FullMerkleWrapper wrapper) {
        wrapper = new FullMerkleWrapper();
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            wrapper.push(AtomicInteropTestUtils.indexedLeafHash(_tree.leafAt(i)));
        }
    }

    function lowNullifierIndex(IL2InteropCommitmentTree _tree, uint256 _value) public view returns (uint256) {
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            IndexedLeaf memory l = _tree.leafAt(i);
            if (l.value < _value && (l.nextValue == 0 || _value < l.nextValue)) {
                return i;
            }
        }
        revert("no low nullifier");
    }

    function indexOfValue(IL2InteropCommitmentTree _tree, uint256 _value) public view returns (uint256) {
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            if (_tree.leafAt(i).value == _value) {
                return i;
            }
        }
        revert("value not present");
    }
}

/// @notice Minimal Bridgehub stand-in: maps chainId => diamond proxy, which {GlobalInteropIMT} uses
/// to authorize the submitter. Isolates the registry's submitter check from the full Bridgehub.
contract MockBridgehub {
    mapping(uint256 chainId => address zkChain) internal _zkChain;

    function setZKChain(uint256 _chainId, address _addr) external {
        _zkChain[_chainId] = _addr;
    }

    function getZKChain(uint256 _chainId) external view returns (address) {
        return _zkChain[_chainId];
    }
}

/// @notice Minimal asset-router stand-in that records the burn/mint calls the escrow makes, so tests
/// can assert the escrow's orchestration without the full AR/NTV stack (the asset movement itself is
/// the AR/NTV's concern, exercised in the heavier anvil-interop suite).
contract MockAtomicAssetRouter {
    uint256 public indirectCallCount;
    uint256 public finalizeDepositCount;
    uint256 public lastChainId;
    bytes32 public lastAssetId;

    function initiateIndirectCall(
        uint256 _chainId,
        address,
        uint256,
        bytes calldata
    ) external payable returns (InteropCallStarter memory starter) {
        ++indirectCallCount;
        lastChainId = _chainId;
        // Return a default (empty) starter; the escrow discards it.
        return starter;
    }

    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata) external payable {
        ++finalizeDepositCount;
        lastChainId = _chainId;
        lastAssetId = _assetId;
    }
}

/// @notice Shared pure helpers mirroring the off-chain coordinator / proof library.
library AtomicInteropTestUtils {
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    function indexedLeafHash(IndexedLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextValue, _leaf.nextIndex));
    }

    function globalLeaf(uint256 _chainId, bytes32 _chainImtRoot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainImtRoot, _chainId));
    }

    function specHashOf(SendSpec memory _spec) internal pure returns (bytes32) {
        return keccak256(abi.encode(_spec));
    }

    /// @notice Computes flowId exactly as {AtomicFlowEscrow}. Both arrays must be strictly ascending.
    function computeFlowId(
        bytes32[] memory _specHashes,
        uint256[] memory _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_specHashes, _chainIds, _deadline));
    }
}
