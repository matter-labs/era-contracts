// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Merkle} from "../../common/libraries/Merkle.sol";
import {ImtInclusionProof, ImtNonInclusionProof, IMT_EMPTY_LEAF, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {
    ProofChainMismatch,
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofGlobalInclusionFailed,
    ProofInclusionFailed,
    ProofLeafPresent,
    ProofNonInclusionRecomputeFailed
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Pure verification helpers for the L1-free atomic interop flow.
///
/// All proofs are resolved against a *global interop-IMT root* that the verifying L2 imported
/// from L1. The escrow resolves the imported root and its L1 timestamp for a given block number
/// and hands them to these helpers, keeping this library free of any storage reads.
///
/// Two layers of Merkle verification are used:
///   - the per-chain interop IMT is an append-only `DynamicIncrementalMerkle` tree, so a proof
///     is valid only against the exact root version (leaf count) it was generated for;
///   - the global IMT is a `FullMerkle` tree whose leaves are per-chain IMT roots, updated in
///     place; the off-chain engine reconstructs the historical version matching the imported
///     root and produces the path.
///
/// Both layers hash with `Merkle.efficientHash` (keccak256 of two words) and use
/// `IMT_EMPTY_LEAF` as the zero value, so on-chain checks reuse `Merkle.calculateRoot`.
library AtomicInteropProof {
    /// @notice Leaf appended to a chain's interop IMT when a flow leg is committed.
    function commitLeaf(bytes32 _flowId, bytes32 _specHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash));
    }

    /// @notice Leaf placed into the global IMT for a chain. Binds the chain's IMT root to its id
    /// so a root cannot be replayed under a different chain.
    function globalLeaf(uint256 _chainId, bytes32 _chainImtRoot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainImtRoot, _chainId));
    }

    /// @notice Verifies that `_commitLeaf` is included in the chain's interop IMT, that the IMT
    /// root is contained in `_importedGlobalRoot`, and that the import happened in time.
    /// @param _proof The layered inclusion proof.
    /// @param _expectedChainId The chain that must own the commit leaf (the leg's `chainId`).
    /// @param _commitLeaf The commit leaf being proven.
    /// @param _importedGlobalRoot The global IMT root the verifying L2 imported for
    /// `_proof.l1BlockNumber`.
    /// @param _importedTimestamp The L1 timestamp recorded for that imported root.
    /// @param _deadline The flow deadline; the imported root must not be later than it.
    function verifyInclusion(
        ImtInclusionProof calldata _proof,
        uint256 _expectedChainId,
        bytes32 _commitLeaf,
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

        bytes32 computedChainRoot = Merkle.calculateRoot(_proof.imtProof, _proof.imtLeafIndex, _commitLeaf);
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

    /// @notice Verifies that `_commitLeaf` is provably absent from the chain's interop IMT across
    /// the deadline boundary, so the flow can no longer finalize.
    /// @param _proof The non-inclusion proof.
    /// @param _expectedChainId The chain that would have owned the commit leaf.
    /// @param _commitLeaf The commit leaf that must be absent.
    /// @param _globalRootBefore Imported global root with L1 timestamp `<= _deadline`.
    /// @param _timestampBefore L1 timestamp of `_globalRootBefore`.
    /// @param _globalRootAfter Imported global root with L1 timestamp `> _deadline`.
    /// @param _timestampAfter L1 timestamp of `_globalRootAfter`.
    /// @param _deadline The flow deadline.
    // solhint-disable-next-line func-named-parameters
    function verifyNonInclusion(
        ImtNonInclusionProof calldata _proof,
        uint256 _expectedChainId,
        bytes32 _commitLeaf,
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

        bytes32 leaf = globalLeaf(_proof.chainId, _proof.chainImtRoot);

        // The chain's IMT root must be the same in the root just before the deadline and in a root
        // strictly after it: the chain settled no new leaves across the boundary, so nothing could
        // have been inserted in time. This is the "two blocks" guard from the design.
        bytes32 computedBefore = Merkle.calculateRoot(_proof.globalProofG1, _proof.globalLeafIndex, leaf);
        if (computedBefore != _globalRootBefore) {
            revert ProofGlobalInclusionFailed(_globalRootBefore, computedBefore);
        }
        bytes32 computedAfter = Merkle.calculateRoot(_proof.globalProofG2, _proof.globalLeafIndex, leaf);
        if (computedAfter != _globalRootAfter) {
            revert ProofGlobalInclusionFailed(_globalRootAfter, computedAfter);
        }

        // Recompute the full incremental root from the disclosed leaf set and confirm it matches
        // the committed chain IMT root, then confirm the target leaf is not among the leaves.
        bytes32 recomputed = incrementalRoot(_proof.leaves);
        if (recomputed != _proof.chainImtRoot) {
            revert ProofNonInclusionRecomputeFailed(_proof.chainImtRoot, recomputed);
        }
        uint256 n = _proof.leaves.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_proof.leaves[i] == _commitLeaf) {
                revert ProofLeafPresent(_commitLeaf);
            }
        }
        // Silence the unused-boundary warning while documenting intent: both roots are validated
        // above; `_globalRootAfter` having a later timestamp is what closes the window.
    }

    /// @notice Recomputes the root of a `DynamicIncrementalMerkle` tree from its full ordered leaf
    /// set, faithfully replicating the on-chain `push` algorithm (including dynamic growth).
    /// @dev O(n log n); intended for the refund path where leaf counts are small in the demo.
    function incrementalRoot(bytes32[] calldata _leaves) internal pure returns (bytes32) {
        uint256 n = _leaves.length;
        if (n == 0) {
            // Matches `DynamicIncrementalMerkle.setup`, whose initial root is `bytes32(0)`.
            return bytes32(0);
        }

        // Max depth supported (mirrors the single-proof bound in `Merkle`).
        bytes32[] memory sides = new bytes32[](256);
        bytes32[] memory zeros = new bytes32[](256);
        zeros[0] = IMT_EMPTY_LEAF;

        uint256 levels = 0;
        bytes32 lastRoot;
        for (uint256 idx = 0; idx < n; ++idx) {
            // Grow the tree exactly as the on-chain library does, when it would overflow.
            if (idx == (uint256(1) << levels)) {
                zeros[levels + 1] = Merkle.efficientHash(zeros[levels], zeros[levels]);
                ++levels;
            }

            uint256 currentIndex = idx;
            bytes32 currentLevelHash = _leaves[idx];
            bool updatedSides = false;
            for (uint256 i = 0; i < levels; ++i) {
                bool isLeft = currentIndex % 2 == 0;
                if (isLeft && !updatedSides) {
                    sides[i] = currentLevelHash;
                    updatedSides = true;
                }
                currentLevelHash = isLeft
                    ? Merkle.efficientHash(currentLevelHash, zeros[i])
                    : Merkle.efficientHash(sides[i], currentLevelHash);
                currentIndex >>= 1;
            }
            sides[levels] = currentLevelHash;
            lastRoot = currentLevelHash;
        }
        return lastRoot;
    }
}
