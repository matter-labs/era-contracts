// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicInteropProof} from "contracts/atomic-interop/libraries/AtomicInteropProof.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH} from "contracts/core/message-root/IMessageRoot.sol";
import {SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_INTEROP_ROOT_STORAGE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice Test-only external re-export of the internal {AtomicInteropProof} library so its
/// `internal`/`view`/`pure` functions can be exercised (and `vm.expectRevert`-ed) from a test.
/// @dev This is NOT a logic mock: every function forwards verbatim to the real library, so the real
/// authentication + clock logic runs. Same pattern as `IndexedMerkleTreeHarness`
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

    function verifyTimeoutAbsence(
        ImtProof calldata _absence,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) external view {
        AtomicInteropProof.verifyTimeoutAbsence(_absence, _commitValue, _deadline, _expectedSlChainId);
    }
}

/// @notice Shared fixtures + on-chain proof builders for the {AtomicInteropProof} unit tests.
/// @dev Mock policy: a REAL {L2InteropCommitmentTree} is the IMT oracle (proofs are assembled from its
/// own `root()`/`leafAt`/`merklePath`, so no second IMT implementation can drift) and a REAL
/// {L2InteropRootStorage} is etched at its canonical address and seeded via the production bootloader
/// entry point. Only `L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared` is mocked — that layer is
/// covered by L2MessageVerification.t.sol; driving it true/false reaches this library's own branches.
/// The mock does NOT bypass the library's own proof parsing (`MessageHashing.parseProofMetadata` /
/// `readSettlementLayerReference` / `readAggregationHopPath`): the `settlementProof` blob built here
/// is still parsed for real (it only needs to parse, not hash to a real root, since the terminal-root
/// check is the mocked verifier's job), so the SL-match / clock / last-batch branches stay live.
abstract contract AtomicInteropProofBuilder is Test {
    /// @dev The flow deadline all proofs are built against (shared with the tests so the builders
    /// can declare the honest timeout branch for a given batch timestamp).
    uint64 internal constant DEADLINE = 1_000;

    AtomicInteropProofWrapper internal proofLib;
    L2InteropCommitmentTree internal tree;
    L2InteropRootStorage internal rootStorage;

    /// @dev Deploys the wrapper + a fresh commitment tree, etches the real interop-root storage at
    /// its canonical address, and seeds the tree.
    function _setUpAtomicFixtures() internal {
        proofLib = new AtomicInteropProofWrapper();
        tree = new L2InteropCommitmentTree();
        // Seeds the `{0,0,0}` head leaf at index 0.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();

        // The timeout protocol reads the root tuple from the canonical address; etch the REAL contract
        // there so tests seed it through the production write path.
        rootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
    }

    // ------------------------------------------------------------------------------------------------
    // Mocks / real-storage seeding
    // ------------------------------------------------------------------------------------------------

    /// @dev Drives the (separately-tested) cross-chain leaf verifier to `_ok` for every call.
    function _mockVerifier(bool _ok) internal {
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared.selector),
            abi.encode(_ok)
        );
    }

    /// @dev Imports the settlement-layer interop root `(root, timestamp)` tuple into the REAL root storage through the
    /// production bootloader entry point.
    function _seedSettlementLayerInteropRoot(uint256 _slChainId, uint256 _slBlock, uint256 _timestamp) internal {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = keccak256(abi.encode("sl-interop-root", _slChainId, _slBlock));
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(
            InteropRoot({chainId: _slChainId, blockOrBatchNumber: _slBlock, timestamp: _timestamp, sides: sides})
        );
    }

    /// @dev Asserts that the proof library authenticates `_proof.chainImtRoot` as exactly the
    /// chain-batch-root leaf `_imtRootLeafIndex` (2 = batch begin, 3 = batch end) of the claimed
    /// batch. The default verifier mock remains selector-wide for branch-driving; this expectation
    /// makes the adapter boundary fail if chain id, batch, leaf index, root, or proof drift.
    function _expectRootAuthentication(ImtProof memory _proof, uint256 _imtRootLeafIndex) internal {
        vm.expectCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(
                L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared.selector,
                _proof.sourceChainId,
                _proof.batchNumber,
                _imtRootLeafIndex,
                _proof.chainImtRoot,
                _proof.settlementProof
            )
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
    // settlementProof-blob assembler
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

    /// @dev A minimal well-formed *non-final* `settlementProof` parsing to the given
    /// `(slChainId, slBlock, l1Timestamp)` and batch-leaf path, with the leaf-to-chain-batch-root
    /// section at exactly {ChainBatchRootTree.TREE_DEPTH} hops as the library enforces. Dummy siblings
    /// suffice: the resulting roots are never checked here because the leaf verifier is mocked.
    /// @param _batchLeafSiblings Batch-leaf path in the chain's batch tree (empty = single-leaf tree,
    /// which trivially satisfies the timeout protocol's last-batch check).
    function _settlementProof(
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp,
        bytes32[] memory _batchLeafSiblings
    ) internal pure returns (bytes32[] memory proof) {
        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        // Layout: [metadata, topSiblings(3), l1Timestamp, batchLeafProofMask, batchSiblings(n),
        //          slPackedInfo, slChainId]
        proof = new bytes32[](topLen + 5 + _batchLeafSiblings.length);
        proof[0] = _composeMetadata({
            _logLeafProofLen: topLen,
            _batchLeafProofLen: _batchLeafSiblings.length,
            _finalProofNode: false
        });
        for (uint256 i = 0; i < topLen; ++i) {
            proof[1 + i] = bytes32(uint256(0xdead)); // dummy top-tree sibling
        }
        proof[topLen + 1] = bytes32(_l1Timestamp);
        proof[topLen + 2] = bytes32(uint256(0)); // batchLeafProofMask (leaf at index 0, left child)
        for (uint256 i = 0; i < _batchLeafSiblings.length; ++i) {
            proof[topLen + 3 + i] = _batchLeafSiblings[i];
        }
        proof[topLen + 3 + _batchLeafSiblings.length] = bytes32(_slBlock << 128); // (slBlock << 128) | mask
        proof[topLen + 4 + _batchLeafSiblings.length] = bytes32(_slChainId);
    }

    /// @dev A *final* `settlementProof` (single-level / commit-based): carries no settlement-layer
    /// batch reference, so `AtomicInteropProof` rejects it with `ProofMissingSettlementLayerBatch`.
    function _finalSettlementProof() internal pure returns (bytes32[] memory proof) {
        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        proof = new bytes32[](topLen + 1);
        proof[0] = _composeMetadata({_logLeafProofLen: topLen, _batchLeafProofLen: 0, _finalProofNode: true});
        for (uint256 i = 0; i < topLen; ++i) {
            proof[1 + i] = bytes32(uint256(0xdead)); // dummy log-leaf-proof sibling
        }
    }

    /// @dev The `DynamicIncrementalMerkle` empty-subtree cascade the settlement layer's chain tree is
    /// built with: `zeros[0] = CHAIN_TREE_EMPTY_ENTRY_HASH`, `zeros[i+1] = keccak(zeros[i] || zeros[i])`.
    /// A batch-leaf path made of these right siblings marks the leaf as the chain's LAST batch.
    function _emptySubtreeCascade(uint256 _levels) internal pure returns (bytes32[] memory siblings) {
        siblings = new bytes32[](_levels);
        bytes32 zero = CHAIN_TREE_EMPTY_ENTRY_HASH;
        for (uint256 i = 0; i < _levels; ++i) {
            siblings[i] = zero;
            zero = keccak256(bytes.concat(zero, zero));
        }
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
        uint256 _slBlock,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                // The finality path always authenticates the end root; the branch bool is ignored.
                provesAgainstBeginRoot: false,
                settlementProof: _settlementProof(_slChainId, _slBlock, _l1Timestamp, new bytes32[](0)),
                leaf: tree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: tree.merklePath(_leafIndex)
            });
    }

    /// @dev Non-inclusion proof for an absent `_absentValue`: uses its low-nullifier (predecessor)
    /// leaf. The empty batch-leaf path marks the batch as the chain's last inside the settlement-layer interop root
    /// (single-leaf chain tree), so the proof is valid for both timeout branches.
    function _nonInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _absentValue,
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                // Declare the branch the way an honest prover does: begin root for a late batch,
                // end root for an in-time one. Tests overriding the declaration set the field
                // explicitly after building.
                provesAgainstBeginRoot: _l1Timestamp > DEADLINE,
                settlementProof: _settlementProof(_slChainId, _slBlock, _l1Timestamp, new bytes32[](0)),
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }
}
