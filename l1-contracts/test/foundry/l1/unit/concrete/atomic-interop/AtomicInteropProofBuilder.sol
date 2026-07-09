// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicInteropProof} from "contracts/atomic-interop/libraries/AtomicInteropProof.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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

/// @notice Shared fixtures + on-chain proof builders for the {AtomicInteropProof} unit tests (PR1).
///
/// Design (mirrors the plan's PR1 harness decision):
///   - A REAL {L2InteropCommitmentTree} is the IMT oracle: we insert commit values through the real
///     `insert` path and read `root()`/`leafAt`/`merklePath` to assemble genuine inclusion /
///     non-inclusion `ImtProof`s. No second (off-chain) IMT implementation is maintained, so on-chain
///     and off-chain layouts cannot drift.
///   - The two system contracts the proof authentication reaches are mocked to ISOLATE this library
///     from separately-tested machinery (justified inline at each mock):
///       * `L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1` — the tree publishes its root on init/insert;
///         the messenger is a system contract, not under test here.
///       * `L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared` — the cross-chain message-inclusion
///         layer is covered by L2MessageVerification.t.sol; here we drive it to true/false to reach the
///         library's own branches. It does NOT bypass `MessageHashing._getProofData`, which still parses
///         the real `messageProof` blob we build below (so the SL-match / deadline branches stay live).
///
/// The `messageProof` blob is a minimal well-formed non-final proof carrying a caller-chosen
/// `(settlementLayerChainId, l1Timestamp)`; `_getProofData` only *parses* it (it does not re-verify the
/// root, which is the mocked verifier's job), so it does not need to hash to any real interop root.
abstract contract AtomicInteropProofBuilder is Test {
    AtomicInteropProofWrapper internal proofLib;
    L2InteropCommitmentTree internal tree;

    /// @dev Deploys the wrapper + a fresh commitment tree, mocks the messenger, and seeds the tree.
    function _setUpAtomicFixtures() internal {
        proofLib = new AtomicInteropProofWrapper();
        tree = new L2InteropCommitmentTree();
        _mockMessenger();
        // Seeds the `{0,0,0}` head leaf at index 0 (and publishes the seed root via the mocked messenger).
        tree.initialize();
    }

    // ------------------------------------------------------------------------------------------------
    // Mocks (system contracts, not under test — see contract docstring)
    // ------------------------------------------------------------------------------------------------

    /// @dev The tree publishes `abi.encode(root)` to L1 on every seed/insert; make that call inert.
    function _mockMessenger() internal {
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );
    }

    /// @dev Drives the (separately-tested) cross-chain message verifier to `_ok` for every call.
    function _mockVerifier(bool _ok) internal {
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(_ok)
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
    // messageProof-blob assembler
    // ------------------------------------------------------------------------------------------------

    /// @dev Builds the proof-metadata word (top 4 bytes: version, logLeafProofLen, batchLeafProofLen,
    /// finalProofNode; remaining bytes zero — the format `MessageHashing.parseProofMetadata` expects).
    function _composeMetadata(
        uint256 _logLeafProofLen,
        uint256 _batchLeafProofLen,
        bool _finalProofNode
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(SUPPORTED_PROOF_METADATA_VERSION) << 248) |
                    (_logLeafProofLen << 240) |
                    (_batchLeafProofLen << 232) |
                    ((_finalProofNode ? uint256(1) : uint256(0)) << 224)
            );
    }

    /// @dev A minimal, well-formed *non-final* `messageProof` that `MessageHashing._getProofData` parses
    /// into `(settlementLayerChainId = _slChainId, l1BatchTimestamp = _l1Timestamp)`. The dummy sibling
    /// words only need to be non-reverting inputs to the internal Merkle hashing; the resulting roots are
    /// never checked here because the message verifier is mocked.
    function _messageProof(uint256 _slChainId, uint256 _l1Timestamp) internal pure returns (bytes32[] memory proof) {
        // Layout: [metadata, logProof(1), l1Timestamp, batchLeafProofMask, batchProof(1), slPackedInfo, slChainId]
        proof = new bytes32[](7);
        proof[0] = _composeMetadata({_logLeafProofLen: 1, _batchLeafProofLen: 1, _finalProofNode: false});
        proof[1] = bytes32(uint256(0xdead)); // dummy log-leaf-proof sibling
        proof[2] = bytes32(_l1Timestamp);
        proof[3] = bytes32(uint256(0)); // batchLeafProofMask (leaf at index 0)
        proof[4] = bytes32(uint256(0xbeef)); // dummy batch-leaf-proof sibling
        proof[5] = bytes32(uint256(0)); // settlementLayerPackedBatchInfo (slBatchNumber<<128 | mask); unused by callers
        proof[6] = bytes32(_slChainId);
    }

    /// @dev A *final* `messageProof` (single-level / commit-based) that carries no settlement-layer
    /// anchor, so `AtomicInteropProof` rejects it with `ProofMissingSettlementLayerAnchor`.
    function _finalMessageProof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = _composeMetadata({_logLeafProofLen: 1, _batchLeafProofLen: 0, _finalProofNode: true});
        proof[1] = bytes32(uint256(0xdead)); // dummy log-leaf-proof sibling
    }

    // ------------------------------------------------------------------------------------------------
    // ImtProof assemblers
    // ------------------------------------------------------------------------------------------------

    /// @dev Inclusion proof for a value already inserted at `_leafIndex` in the real tree.
    function _inclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: _messageProof(_slChainId, _l1Timestamp),
                leaf: tree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: tree.merklePath(_leafIndex)
            });
    }

    /// @dev Non-inclusion proof for an absent `_absentValue`: uses its low-nullifier (predecessor) leaf.
    function _nonInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _absentValue,
        uint256 _slChainId,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: _messageProof(_slChainId, _l1Timestamp),
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }

    /// @dev A bare root-authentication proof (the timeout `successor` witness). Only its authenticated
    /// `(sourceChainId, batchNumber, slChainId, l1Timestamp)` matter; its IMT-membership fields are unused
    /// by `verifyTimeoutAdjacency`, so they are left empty.
    function _rootAuthProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _slChainId,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: _messageProof(_slChainId, _l1Timestamp),
                leaf: IMTLeaf({value: 0, nextIndex: 0, nextValue: 0}),
                imtLeafIndex: 0,
                imtProof: new bytes32[](0)
            });
    }
}
