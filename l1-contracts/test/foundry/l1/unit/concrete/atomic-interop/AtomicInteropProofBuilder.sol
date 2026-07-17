// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InteropVerificationFixture} from "./InteropVerificationFixture.sol";
import {InteropInclusionProofLib} from "./InteropInclusionProofLib.sol";

import {AtomicInteropProof} from "contracts/atomic-interop/libraries/AtomicInteropProof.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    L2_MESSAGE_VERIFICATION,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice Test-only external re-export of the internal {AtomicInteropProof} library so its
/// `internal`/`view`/`pure` functions can be exercised (and `vm.expectRevert`-ed) from a test.
/// @dev This is NOT a logic mock: every function forwards verbatim to the real library, so the real
/// authentication + deadline logic runs. Same pattern as `IndexedMerkleTreeHarness`
/// (IndexedMerkleTree.t.sol) and `AttributesDecoderWrapper` (AttributesDecoder.t.sol).
contract AtomicInteropProofWrapper {
    function commitValue(bytes32 _flowId, bytes32 _bundleHash) external pure returns (uint256) {
        return AtomicInteropProof.commitValue(_flowId, _bundleHash);
    }

    function verifyInclusion(
        ImtProof calldata _proof,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) external view {
        AtomicInteropProof.verifyInclusion(_proof, _commitValue, _deadline, _expectedSlChainId);
    }

    function verifyTimeoutAdjacency(
        ImtProof calldata _absence,
        ImtProof calldata _successor,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) external view {
        AtomicInteropProof.verifyTimeoutAdjacency(_absence, _successor, _commitValue, _deadline, _expectedSlChainId);
    }
}

/// @notice Shared fixtures + on-chain proof builders for the {AtomicInteropProof} unit tests.
///
/// Design:
///   - A REAL {L2InteropCommitmentTree} is the IMT oracle: we insert commit values through the real
///     `insert` path and read `root()`/`leafAt`/`merklePath` to assemble genuine inclusion /
///     non-inclusion `ImtProof`s. No second (off-chain) IMT implementation is maintained, so on-chain
///     and off-chain layouts cannot drift.
///   - The cross-chain message verifier is REAL too (see {InteropVerificationFixture}): every
///     `messageProof` is a genuine inclusion proof built by {InteropInclusionProofLib}, and each builder
///     seeds the imported interop root the real recursion resolves against. `proveL2MessageInclusionShared`
///     therefore runs for real — a proof is authenticated iff its root was actually imported, so the
///     "root not included" branch is reached by *withholding* the seed, not by mocking a `false`.
///   - The only stub is the L2->L1 messenger (`sendToL1`): the commitment tree publishes its root on
///     seed/insert, but that publish is an unrelated system-contract side-effect, not the authentication
///     logic under test. It is made inert (justified inline at `_mockMessenger`).
///
/// Each proof is anchored at a fresh settlement-layer block (`_nextSlBlock`) so that seeding one proof's
/// interop root never overwrites another's within the same test.
abstract contract AtomicInteropProofBuilder is InteropVerificationFixture {
    AtomicInteropProofWrapper internal proofLib;
    L2InteropCommitmentTree internal tree;

    /// @dev Monotonic settlement-layer block counter; each built proof gets its own anchor block so their
    /// imported interop roots occupy distinct `interopRoots[slChainId][slBlock]` slots.
    uint256 private slBlockNonce;

    /// @dev Deploys the wrapper + a fresh commitment tree + the real verifier stack, and seeds the tree.
    function _setUpAtomicFixtures() internal {
        proofLib = new AtomicInteropProofWrapper();
        tree = new L2InteropCommitmentTree();
        _mockMessenger();
        _deployMessageVerification();
        // Seeds the `{0,0,0}` head leaf at index 0 (and publishes the seed root via the mocked messenger).
        tree.initialize();
    }

    // ------------------------------------------------------------------------------------------------
    // Messenger stub (system contract, not under test — see contract docstring)
    // ------------------------------------------------------------------------------------------------

    /// @dev The tree publishes `abi.encode(root)` to L1 on every seed/insert; make that call inert.
    function _mockMessenger() internal {
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );
    }

    /// @dev Asserts that the proof library authenticates exactly the root-publishing message for `_proof`.
    /// This makes the adapter boundary fail if chain id, batch, index, sender, encoded root, tx number, or
    /// proof drift between the {ImtProof} and the `proveL2MessageInclusionShared` call.
    function _expectRootAuthentication(ImtProof memory _proof) internal {
        vm.expectCall(address(L2_MESSAGE_VERIFICATION), _rootAuthenticationCall(_proof));
    }

    function _rootAuthenticationCall(ImtProof memory _proof) internal pure returns (bytes memory) {
        L2Message memory message = L2Message({
            txNumberInBatch: _proof.messageTxNumberInBatch,
            sender: L2_INTEROP_COMMITMENT_TREE_ADDR,
            data: abi.encode(_proof.chainImtRoot)
        });

        return
            abi.encodeWithSelector(
                L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector,
                _proof.sourceChainId,
                _proof.batchNumber,
                _proof.messageIndex,
                message,
                _proof.messageProof
            );
    }

    // ------------------------------------------------------------------------------------------------
    // Tree helpers
    // ------------------------------------------------------------------------------------------------

    function _commitValue(bytes32 _flowId, bytes32 _bundleHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _bundleHash)));
    }

    /// @dev Inserts `_value` into the real tree as the canonical appender; returns its leaf index.
    function _insertCommit(uint256 _value) internal returns (uint256 index) {
        uint256 low = _lowNullifierIndex(_value);
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (index, ) = tree.insert(_value, low);
    }

    /// @dev Finds the leaf that brackets `_value` in the sorted linked list (its low-nullifier /
    /// predecessor). Reverts if `_value` is already present — by design there is no bracketing leaf for
    /// a present value, which is exactly why an in-tree value cannot be given a non-inclusion proof.
    function _lowNullifierIndex(uint256 _value) internal view returns (uint256) {
        uint256 count = tree.leafCount();
        for (uint256 i = 0; i < count; ++i) {
            IMTLeaf memory leaf = tree.leafAt(i);
            if (leaf.value < _value && (leaf.nextValue == 0 || leaf.nextValue > _value)) {
                return i;
            }
        }
        revert("AtomicInteropProofBuilder: no low-nullifier (value present or tree empty)");
    }

    /// @dev Finds the leaf whose `nextValue == _value`, i.e. the predecessor of a *present* value. Used to
    /// build an (illegitimate) non-inclusion proof for an in-tree value and show the engine rejects it.
    function _predecessorIndexOf(uint256 _value) internal view returns (uint256) {
        uint256 count = tree.leafCount();
        for (uint256 i = 0; i < count; ++i) {
            if (tree.leafAt(i).nextValue == _value) {
                return i;
            }
        }
        revert("AtomicInteropProofBuilder: no predecessor (value absent)");
    }

    // ------------------------------------------------------------------------------------------------
    // Real messageProof + interop-root seeding
    // ------------------------------------------------------------------------------------------------

    function _nextSlBlock() private returns (uint256) {
        return ++slBlockNonce;
    }

    /// @dev The root-publishing message the commitment tree emits: sender pinned to the tree, data the
    /// encoded root. Its inclusion is what {AtomicInteropProof} authenticates.
    function _commitMessage(uint16 _txNumberInBatch) private view returns (L2Message memory) {
        return
            L2Message({
                txNumberInBatch: _txNumberInBatch,
                sender: L2_INTEROP_COMMITMENT_TREE_ADDR,
                data: abi.encode(tree.root())
            });
    }

    /// @dev Builds a real `messageProof` for the tree's current root and (optionally) seeds the imported
    /// interop root it resolves to. When `_seed` is false the proof is well-formed but unauthenticated,
    /// so the real verifier returns false — the "root not included" case.
    function _buildRootProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp,
        uint16 _txNumberInBatch,
        uint256 _messageIndex,
        bytes32[] memory _logSiblings,
        bool _seed
    ) private returns (bytes32[] memory messageProof) {
        uint256 slBlock = _nextSlBlock();
        bytes32 interopRoot;
        (messageProof, interopRoot) = InteropInclusionProofLib.buildInclusionProof(
            InteropInclusionProofLib.Params({
                message: _commitMessage(_txNumberInBatch),
                messageIndex: _messageIndex,
                logLeafSiblings: _logSiblings,
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                slChainId: _slChainId,
                slBlock: slBlock,
                l1BatchTimestamp: _l1BatchTimestamp
            })
        );
        if (_seed) {
            _seedInteropRoot(_slChainId, slBlock, interopRoot);
        }
    }

    /// @dev A real, seeded root-authentication `messageProof` (single-leaf, zero coordinates) for callers
    /// that assemble a bespoke {ImtProof} (e.g. one carrying a hand-picked membership leaf).
    function _seededRootProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp
    ) internal returns (bytes32[] memory) {
        return
            _buildRootProof(_sourceChainId, _batchNumber, _slChainId, _l1BatchTimestamp, 0, 0, new bytes32[](0), true);
    }

    // ------------------------------------------------------------------------------------------------
    // ImtProof assemblers
    // ------------------------------------------------------------------------------------------------

    /// @dev Inclusion proof for a value already inserted at `_leafIndex`, authenticated by a real,
    /// seeded root proof so `proveL2MessageInclusionShared` verifies for real.
    function _inclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp
    ) internal returns (ImtProof memory) {
        return
            _assembleInclusion(
                _sourceChainId,
                _batchNumber,
                _leafIndex,
                _slChainId,
                _l1BatchTimestamp,
                0,
                0,
                new bytes32[](0),
                true
            );
    }

    /// @dev Like {_inclusionProof} but with caller-chosen message coordinates and a wider log tree, so the
    /// forwarding of `messageTxNumberInBatch` / `messageIndex` to the verifier is exercised end-to-end.
    function _inclusionProofWithCoordinates(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp,
        uint16 _txNumberInBatch,
        uint256 _messageIndex,
        bytes32[] memory _logSiblings
    ) internal returns (ImtProof memory) {
        return
            _assembleInclusion(
                _sourceChainId,
                _batchNumber,
                _leafIndex,
                _slChainId,
                _l1BatchTimestamp,
                _txNumberInBatch,
                _messageIndex,
                _logSiblings,
                true
            );
    }

    /// @dev Inclusion proof whose imported root is deliberately NOT seeded, so the real verifier cannot
    /// authenticate it (`proveL2MessageInclusionShared` returns false).
    function _unresolvedInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp
    ) internal returns (ImtProof memory) {
        return
            _assembleInclusion(
                _sourceChainId,
                _batchNumber,
                _leafIndex,
                _slChainId,
                _l1BatchTimestamp,
                0,
                0,
                new bytes32[](0),
                false
            );
    }

    function _assembleInclusion(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp,
        uint16 _txNumberInBatch,
        uint256 _messageIndex,
        bytes32[] memory _logSiblings,
        bool _seed
    ) private returns (ImtProof memory) {
        bytes32[] memory messageProof = _buildRootProof(
            _sourceChainId,
            _batchNumber,
            _slChainId,
            _l1BatchTimestamp,
            _txNumberInBatch,
            _messageIndex,
            _logSiblings,
            _seed
        );
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: _txNumberInBatch,
                messageIndex: _messageIndex,
                messageProof: messageProof,
                leaf: tree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: tree.merklePath(_leafIndex)
            });
    }

    /// @dev A *final* (single-hop) proof carrying no settlement-layer anchor, authenticated against the
    /// direct interop root at `(sourceChainId, batchNumber)`. {AtomicInteropProof} accepts the inclusion
    /// then rejects the flow with {ProofMissingSettlementLayerAnchor}.
    function _missingAnchorProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex
    ) internal returns (ImtProof memory) {
        (bytes32[] memory messageProof, bytes32 interopRoot) = InteropInclusionProofLib.buildFinalNodeProof(
            _commitMessage(0),
            0,
            new bytes32[](0)
        );
        // A final node is checked directly against interopRoots[sourceChainId][batchNumber].
        _seedInteropRoot(_sourceChainId, _batchNumber, interopRoot);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: messageProof,
                leaf: tree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: tree.merklePath(_leafIndex)
            });
    }

    /// @dev Non-inclusion proof for an absent `_absentValue`: uses its low-nullifier (predecessor) leaf,
    /// authenticated by a real, seeded root proof.
    function _nonInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _absentValue,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp
    ) internal returns (ImtProof memory) {
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        bytes32[] memory messageProof = _buildRootProof(
            _sourceChainId,
            _batchNumber,
            _slChainId,
            _l1BatchTimestamp,
            0,
            0,
            new bytes32[](0),
            true
        );
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: messageProof,
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }

    /// @dev A bare root-authentication proof (the timeout `successor` witness). Only its authenticated
    /// `(sourceChainId, batchNumber, slChainId, l1BatchTimestamp)` matter; its IMT-membership fields are
    /// unused by `verifyTimeoutAdjacency`, so they are left empty.
    function _rootAuthProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _slChainId,
        uint256 _l1BatchTimestamp
    ) internal returns (ImtProof memory) {
        bytes32[] memory messageProof = _buildRootProof(
            _sourceChainId,
            _batchNumber,
            _slChainId,
            _l1BatchTimestamp,
            0,
            0,
            new bytes32[](0),
            true
        );
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: messageProof,
                leaf: IMTLeaf({value: 0, nextIndex: 0, nextValue: 0}),
                imtLeafIndex: 0,
                imtProof: new bytes32[](0)
            });
    }
}
