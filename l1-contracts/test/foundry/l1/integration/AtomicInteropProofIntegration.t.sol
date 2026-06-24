// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {L2_INTEROP_ROOT_STORAGE} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {ImtInclusionProof, ImtTimeoutProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    AtomicDeadlineExceeded,
    AtomicDeadlineNotExceeded,
    AtomicRootMessageInclusionFailed
} from "contracts/atomic-interop/AtomicInteropErrors.sol";

import {
    AtomicInteropProofHarness,
    InteropCommitmentTreeHarness
} from "test/foundry/l1/unit/concrete/AtomicInterop/AtomicInteropTestUtils.sol";

/// @title Integration test: {AtomicInteropProof} against the REAL {L2MessageVerification}.
/// @notice Exercises the verifier end-to-end through the genuine message-verification pipeline: a real
/// {L2MessageVerification} recursion, the real {MessageHashing._getProofData} parse, and the real
/// {IndexedMerkleTree} membership engine, driven by a real two-hop (source-chain -> settlement-layer) proof.
/// The IMT membership branches are covered at unit level ({AtomicInteropProof.t.sol}); the tests here are
/// exactly the ones the real verifier influences — message reconstruction, sender binding, and the
/// settlement-block-bound-to-root property.
/// @dev Mocking & harness notes (AGENTS.md: mock only to isolate, with a reason):
///  - The ONLY mock is the bootloader-imported `interopRoots` value: in production it is written solely by
///    `L2InteropRootStorage` under `onlyCallFromBootloader`, and there is no sequencer in a Foundry run, so a
///    genuine entry cannot be produced by any contract call. Every message-verification test in the repo
///    (e.g. `L2MessageVerification.t.sol`) mocks it the same way.
///  - This file deliberately does NOT use the `_SharedL1ContractDeployer` full-system harness the other
///    files here use. The verifier only accepts a NON-FINAL two-hop proof anchored at an imported interop
///    root, which routes through `L2MessageVerification`; the deployed `L1MessageRoot` instead verifies
///    against its own `chainBatchRoots` (a final-node proof) and would be rejected by `_authenticateRoot`.
///    With the L2 commitment tree / flow manager out of scope, the shared-deployer harness would add
///    deployment cost without adding realism — the real verifier + a hand-built proof + the single
///    `interopRoots` mock is the maximal-fidelity shape.
contract AtomicInteropProofIntegrationTest is Test {
    AtomicInteropProofHarness internal harness;
    L2MessageVerification internal verifier;
    InteropCommitmentTreeHarness internal imt;

    address internal constant COMMITMENT_TREE = address(0x10012);
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SL_CHAIN_ID = 506;
    uint256 internal constant BATCH_NUMBER = 7;
    uint256 internal constant SL_BLOCK = 4242;

    uint256 internal constant SUPPORTED_PROOF_METADATA_VERSION = 1;

    function setUp() public {
        harness = new AtomicInteropProofHarness();
        verifier = new L2MessageVerification();
        imt = new InteropCommitmentTreeHarness();
        imt.setup();
    }

    function test_EndToEnd_InclusionAgainstRealVerifier() public {
        uint256 commit = harness.commitValue(keccak256("flow"), keccak256("spec"));
        imt.insert(commit, 0);
        bytes32 imtRoot = imt.root();

        (bytes32[] memory messageProof, bytes32 interopRoot) = _buildRecursiveProof(imtRoot);
        _mockImportedInteropRoot(interopRoot);

        uint256 idx = imt.indexOfValue(commit);
        ImtInclusionProof memory proof = ImtInclusionProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_NUMBER,
            chainImtRoot: imtRoot,
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: messageProof,
            leaf: imt.leafAt(idx),
            imtLeafIndex: idx,
            imtProof: imt.merklePath(idx)
        });

        // Real verifier authenticates the root message; the library reads SL_BLOCK from the same proof.
        uint256 slChainId = harness.verifyInclusion(
            proof,
            IMessageVerification(address(verifier)),
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            commit,
            SL_BLOCK // deadline == slBlock: included exactly on time.
        );
        assertEq(slChainId, SL_CHAIN_ID, "settlement-layer chain id from the real proof");

        // A deadline before the settlement block rejects the same proof.
        vm.expectRevert(abi.encodeWithSelector(AtomicDeadlineExceeded.selector, SL_BLOCK, SL_BLOCK - 1));
        harness.verifyInclusion(
            proof,
            IMessageVerification(address(verifier)),
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            commit,
            SL_BLOCK - 1
        );
    }

    function test_EndToEnd_TimeoutAgainstRealVerifier() public {
        // Populate the tree so an absent value has a real low nullifier, but prove a never-committed value.
        imt.insert(harness.commitValue(keccak256("flow"), keccak256("present")), 0);
        uint256 absent = harness.commitValue(keccak256("flow"), keccak256("never"));
        bytes32 imtRoot = imt.root();

        (bytes32[] memory messageProof, bytes32 interopRoot) = _buildRecursiveProof(imtRoot);
        _mockImportedInteropRoot(interopRoot);

        uint256 lowIdx = imt.lowNullifierIndex(absent);
        ImtTimeoutProof memory proof = ImtTimeoutProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_NUMBER,
            chainImtRoot: imtRoot,
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: messageProof,
            lowLeaf: imt.leafAt(lowIdx),
            lowLeafIndex: lowIdx,
            imtProof: imt.merklePath(lowIdx)
        });

        // slBlock (4242) > deadline (4241): the leg can no longer be committed in time.
        harness.verifyTimeout(
            proof,
            IMessageVerification(address(verifier)),
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            absent,
            SL_BLOCK - 1
        );

        // deadline == slBlock fails (strict `>`).
        vm.expectRevert(abi.encodeWithSelector(AtomicDeadlineNotExceeded.selector, SL_BLOCK, SL_BLOCK));
        harness.verifyTimeout(
            proof,
            IMessageVerification(address(verifier)),
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            absent,
            SL_BLOCK
        );
    }

    /// @notice A wrong commitment-tree sender is rejected by the REAL verifier — the property the mocked
    /// unit tests cannot exercise. With the correct interop root imported, reconstructing the message from
    /// a different sender yields a different leaf, so the real recursive verification fails.
    function test_EndToEnd_WrongSenderRejectedByRealVerifier() public {
        uint256 commit = harness.commitValue(keccak256("flow"), keccak256("spec"));
        imt.insert(commit, 0);
        bytes32 imtRoot = imt.root();

        (bytes32[] memory messageProof, bytes32 interopRoot) = _buildRecursiveProof(imtRoot);
        _mockImportedInteropRoot(interopRoot); // imported root is for the CORRECT sender

        uint256 idx = imt.indexOfValue(commit);
        ImtInclusionProof memory proof = ImtInclusionProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_NUMBER,
            chainImtRoot: imtRoot,
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: messageProof,
            leaf: imt.leafAt(idx),
            imtLeafIndex: idx,
            imtProof: imt.merklePath(idx)
        });

        vm.expectRevert(
            abi.encodeWithSelector(AtomicRootMessageInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_NUMBER)
        );
        harness.verifyInclusion(
            proof,
            IMessageVerification(address(verifier)),
            address(0xBAD), // wrong sender => different message leaf => real verifier rejects
            SOURCE_CHAIN_ID,
            commit,
            SL_BLOCK
        );
    }

    /// @notice The flagship non-spoofable-deadline property: the settlement-layer block the deadline is
    /// compared against is provably the one whose imported interop root authenticated the root, so a prover
    /// cannot detach the deadline block from the authenticated root. Here interopRoots is imported ONLY at
    /// the genuine (SL_CHAIN_ID, SL_BLOCK); a proof carrying any other slBlock queries an unimported key and
    /// is rejected by the real verifier. The argument-blind mocks in the other tests cannot exercise this.
    function test_EndToEnd_SlBlockIsBoundToAuthenticatedRoot() public {
        uint256 commit = harness.commitValue(keccak256("flow"), keccak256("spec"));
        imt.insert(commit, 0);
        bytes32 imtRoot = imt.root();
        uint256 idx = imt.indexOfValue(commit);

        (, bytes32 interopRoot) = _buildRecursiveProof(imtRoot);
        _mockImportedInteropRootForKey(SL_BLOCK, interopRoot); // imported ONLY at the genuine SL block

        // A proof carrying the genuine slBlock authenticates and returns it.
        (bytes32[] memory goodProof, ) = _buildRecursiveProofWithSlBlock(imtRoot, SL_BLOCK);
        ImtInclusionProof memory ok = ImtInclusionProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_NUMBER,
            chainImtRoot: imtRoot,
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: goodProof,
            leaf: imt.leafAt(idx),
            imtLeafIndex: idx,
            imtProof: imt.merklePath(idx)
        });
        uint256 slChainId = harness.verifyInclusion(
            ok,
            IMessageVerification(address(verifier)),
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            commit,
            SL_BLOCK
        );
        assertEq(slChainId, SL_CHAIN_ID, "genuine slBlock authenticates");

        // The SAME proof except for a DIFFERENT slBlock queries interopRoots(SL_CHAIN_ID, SL_BLOCK + 1),
        // which is not imported (returns 0), so the real verifier rejects it. The deadline is set so that,
        // were authentication to (wrongly) succeed, the deadline check would pass — isolating the revert to
        // the authentication failure.
        (bytes32[] memory forgedProof, ) = _buildRecursiveProofWithSlBlock(imtRoot, SL_BLOCK + 1);
        ImtInclusionProof memory bad = ImtInclusionProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_NUMBER,
            chainImtRoot: imtRoot,
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: forgedProof,
            leaf: imt.leafAt(idx),
            imtLeafIndex: idx,
            imtProof: imt.merklePath(idx)
        });
        vm.expectRevert(
            abi.encodeWithSelector(AtomicRootMessageInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_NUMBER)
        );
        harness.verifyInclusion(
            bad,
            IMessageVerification(address(verifier)),
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            commit,
            SL_BLOCK + 1
        );
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds a real two-hop message-inclusion proof for the commitment-tree root message (anchored at
    /// the canonical `SL_BLOCK`), and the settlement-layer interop root it must be checked against.
    function _buildRecursiveProof(
        bytes32 _imtRoot
    ) internal view returns (bytes32[] memory proof, bytes32 interopRoot) {
        return _buildRecursiveProofWithSlBlock(_imtRoot, SL_BLOCK);
    }

    /// @dev As {_buildRecursiveProof} but with an explicit settlement-layer block, so a test can vary the
    /// slBlock the proof carries while keeping the authenticated root fixed. Minimal-depth trees keep all
    /// Merkle paths empty: the single L2->L1 log is the batch root, the single batch is the chain root, and
    /// the single chain is the shared root, so the verifier's terminal node compares the imported interop
    /// root to `chainIdLeafHash(batchLeafHash(logLeaf, batchNumber), sourceChainId)`.
    function _buildRecursiveProofWithSlBlock(
        bytes32 _imtRoot,
        uint256 _slBlock
    ) internal view returns (bytes32[] memory proof, bytes32 interopRoot) {
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: COMMITMENT_TREE, data: abi.encode(_imtRoot)});
        bytes32 logLeaf = MessageHashing.getLeafHashFromMessage(message);
        bytes32 batchRoot = logLeaf; // single log => batch L2->L1 log root is the leaf itself
        bytes32 chainRoot = MessageHashing.batchLeafHash(batchRoot, BATCH_NUMBER); // single batch
        interopRoot = MessageHashing.chainIdLeafHash(chainRoot, SOURCE_CHAIN_ID); // single chain => shared root

        // Layout (all proof paths empty; see MessageHashing._getProofData + L2MessageVerification):
        //   [0] top metadata: v1, logLeafProofLen=0, batchLeafProofLen=0, finalProofNode=0
        //   [1] batchLeafProofMask (unused)
        //   [2] packed settlement info: (slBlock << 128) | slMask(=chain index 0)
        //   [3] settlement-layer chain id
        //   [4] SL sub-proof metadata: v1, lengths 0, finalProofNode=1  (terminal interopRoots check)
        proof = new bytes32[](5);
        proof[0] = bytes32(SUPPORTED_PROOF_METADATA_VERSION << 248);
        proof[1] = bytes32(uint256(0));
        proof[2] = bytes32(_slBlock << 128);
        proof[3] = bytes32(SL_CHAIN_ID);
        proof[4] = bytes32((SUPPORTED_PROOF_METADATA_VERSION << 248) | (uint256(1) << 224));
    }

    /// @dev Mocks the bootloader-imported interop root the verifier's terminal node checks against, for any
    /// (chainId, blockNumber) key.
    function _mockImportedInteropRoot(bytes32 _interopRoot) internal {
        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector),
            abi.encode(_interopRoot)
        );
    }

    /// @dev Imports `_interopRoot` ONLY at the genuine `(SL_CHAIN_ID, _slBlock)` key; every other key
    /// returns 0 (not imported). Used to prove that a proof carrying a different slBlock fails the
    /// verifier's terminal interopRoots equality.
    function _mockImportedInteropRootForKey(uint256 _slBlock, bytes32 _interopRoot) internal {
        // Catch-all: any key is "not imported" (returns 0)...
        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector),
            abi.encode(bytes32(0))
        );
        // ...except the genuine key, which returns the real root (the more-specific mock takes precedence).
        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector, SL_CHAIN_ID, _slBlock),
            abi.encode(_interopRoot)
        );
    }
}
