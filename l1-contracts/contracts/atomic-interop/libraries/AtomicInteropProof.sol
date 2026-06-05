// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Merkle} from "../../common/libraries/Merkle.sol";
import {ImtInclusionProof, ImtNonInclusionProof, IndexedLeaf, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {
    ProofChainMismatch,
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofGlobalInclusionFailed,
    ProofInclusionFailed,
    ProofLowNullifierNotAbove,
    ProofLowNullifierNotBelow,
    ProofValueMismatch
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Pure verification helpers for the L1-free atomic interop flow.
///
/// All proofs are resolved against a *global interop-IMT root* that the verifying L2 imported
/// from L1. The escrow resolves the imported root and its L1 timestamp for a given block number
/// and hands them to these helpers, keeping this library free of any storage reads.
///
/// The per-chain interop IMT is an **Indexed Merkle Tree**: each {IndexedLeaf} stores its `value`
/// plus a pointer (`nextValue`, `nextIndex`) to the next-larger value, forming a sorted linked
/// list over the append-only leaf array. This yields O(log n) proofs for *both* membership (a
/// normal Merkle path to the leaf whose `value` matches) and non-membership (a Merkle path to the
/// single "low nullifier" leaf that brackets the absent value).
///
/// The global IMT is a `FullMerkle` tree whose leaves are per-chain IMT roots, updated in place;
/// the off-chain engine reconstructs the historical version matching the imported root.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Hash of an indexed-tree leaf (the value stored at a tree slot).
    function indexedLeafHash(IndexedLeaf calldata _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextValue, _leaf.nextIndex));
    }

    /// @notice Leaf placed into the global IMT for a chain. Binds the chain's IMT root to its id so
    /// a root cannot be replayed under a different chain.
    function globalLeaf(uint256 _chainId, bytes32 _chainImtRoot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainImtRoot, _chainId));
    }

    /// @notice Verifies that `_commitValue` is included in the chain's interop IMT, that the IMT
    /// root is contained in `_importedGlobalRoot`, and that the import happened in time.
    function verifyInclusion(
        ImtInclusionProof calldata _proof,
        uint256 _expectedChainId,
        uint256 _commitValue,
        bytes32 _importedGlobalRoot,
        uint256 _importedTimestamp,
        uint64 _deadline
    ) internal pure {
        if (_proof.chainId != _expectedChainId) {
            revert ProofChainMismatch(_expectedChainId, _proof.chainId);
        }
        if (_importedTimestamp > _deadline) {
            revert ProofDeadlineExceeded(_importedTimestamp, _deadline);
        }
        if (_proof.leaf.value != _commitValue) {
            revert ProofValueMismatch(_commitValue, _proof.leaf.value);
        }

        bytes32 computedChainRoot = Merkle.calculateRoot(
            _proof.imtProof,
            _proof.imtLeafIndex,
            indexedLeafHash(_proof.leaf)
        );
        if (computedChainRoot != _proof.chainImtRoot) {
            revert ProofInclusionFailed(_proof.chainImtRoot, computedChainRoot);
        }

        bytes32 computedGlobalRoot = Merkle.calculateRoot(
            _proof.globalProof,
            _proof.globalLeafIndex,
            globalLeaf(_proof.chainId, _proof.chainImtRoot)
        );
        if (computedGlobalRoot != _importedGlobalRoot) {
            revert ProofGlobalInclusionFailed(_importedGlobalRoot, computedGlobalRoot);
        }
    }

    /// @notice Verifies, in O(log n), that `_commitValue` is absent from the chain's interop IMT
    /// across the deadline boundary, so the flow can no longer finalize.
    /// @param _proof The non-inclusion (low-nullifier) proof.
    /// @param _expectedChainId The chain that would have owned the commit value.
    /// @param _commitValue The value that must be absent.
    /// @param _globalRootBefore Imported global root with L1 timestamp `<= _deadline`.
    /// @param _timestampBefore L1 timestamp of `_globalRootBefore`.
    /// @param _globalRootAfter Imported global root with L1 timestamp `> _deadline`.
    /// @param _timestampAfter L1 timestamp of `_globalRootAfter`.
    /// @param _deadline The flow deadline.
    // solhint-disable-next-line func-named-parameters
    function verifyNonInclusion(
        ImtNonInclusionProof calldata _proof,
        uint256 _expectedChainId,
        uint256 _commitValue,
        bytes32 _globalRootBefore,
        uint256 _timestampBefore,
        bytes32 _globalRootAfter,
        uint256 _timestampAfter,
        uint64 _deadline
    ) internal pure {
        if (_proof.chainId != _expectedChainId) {
            revert ProofChainMismatch(_expectedChainId, _proof.chainId);
        }
        if (_timestampBefore > _deadline) {
            revert ProofDeadlineExceeded(_timestampBefore, _deadline);
        }
        if (_timestampAfter <= _deadline) {
            revert ProofDeadlineNotExceeded(_timestampAfter, _deadline);
        }

        // Low-nullifier bracket: lowLeaf.value < commitValue < lowLeaf.nextValue (or nextValue == 0,
        // meaning lowLeaf is the current maximum). This certifies `_commitValue` is not in the tree.
        if (_proof.lowLeaf.value >= _commitValue) {
            revert ProofLowNullifierNotBelow(_commitValue, _proof.lowLeaf.value);
        }
        if (_proof.lowLeaf.nextValue != 0 && _commitValue >= _proof.lowLeaf.nextValue) {
            revert ProofLowNullifierNotAbove(_commitValue, _proof.lowLeaf.nextValue);
        }

        // The low-nullifier leaf must be a member of the chain IMT root.
        bytes32 lowHash = indexedLeafHash(_proof.lowLeaf);
        bytes32 computedChainRoot = Merkle.calculateRoot(_proof.imtProof, _proof.lowLeafIndex, lowHash);
        if (computedChainRoot != _proof.chainImtRoot) {
            revert ProofInclusionFailed(_proof.chainImtRoot, computedChainRoot);
        }

        // The same chain IMT root must appear in a global root before the deadline and in one after
        // it: the chain settled nothing new across the boundary, so the value could not have been
        // inserted in time.
        bytes32 gLeaf = globalLeaf(_proof.chainId, _proof.chainImtRoot);
        bytes32 computedBefore = Merkle.calculateRoot(_proof.globalProofG1, _proof.globalLeafIndex, gLeaf);
        if (computedBefore != _globalRootBefore) {
            revert ProofGlobalInclusionFailed(_globalRootBefore, computedBefore);
        }
        bytes32 computedAfter = Merkle.calculateRoot(_proof.globalProofG2, _proof.globalLeafIndex, gLeaf);
        if (computedAfter != _globalRootAfter) {
            revert ProofGlobalInclusionFailed(_globalRootAfter, computedAfter);
        }
    }
}
