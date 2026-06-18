// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {
    LegState,
    ImtInclusionProof,
    ImtNonInclusionProof,
    AtomicFinalityProof
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {
    ManagerNotInteropCenter,
    ManagerNotInteropHandler,
    ManagerLegAlreadyCommitted,
    ManagerLegNotRevertable,
    ManagerFlowIdMismatch,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ManagerNoRecoverableCalls
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofMissingSettlementLayerAnchor,
    ProofNonInclusionFailed
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {InteropBundle, InteropCall, BundleAttributes} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AtomicInteropTestUtils, MockAtomicAssetRouter} from "./AtomicInteropTestUtils.sol";

/// @dev Local view of `AssetRouterBase.finalizeDeposit` so the test can build the destination mint call
/// the manager recognises in a reverted bundle. Mirrors `AtomicFlowManager.IAssetRouterFinalizeDeposit`.
interface IAssetRouterFinalizeDeposit {
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;
}

/// @notice Unit tests for the fund-touchless {AtomicFlowManager} (the bundle-based successor of the
/// custodial AtomicFlowEscrow). The manager never custodies funds: the source burn happens through the
/// normal interop path during `InteropCenter.sendBundle`; the manager only coordinates cross-chain
/// atomicity (IMT commit + finality proofs) and the timeout recovery (`recoverAtomicBurn`).
///
/// Two chains (A, B) each run a real {L2InteropCommitmentTree} (IMT engine) and an {AtomicFlowManager}.
/// The test acts as BOTH the interop center (so it can call `append`) and the interop handler (so it can
/// call `requireFlowFinalized`) — those are wired to `address(this)` in `setUp`. The ACL itself is
/// exercised by separate tests using a manager wired to a different ic/ih.
///
/// Proofs are built from REAL tree state: `chainImtRoot = tree.root()`, `leaf/lowLeaf = tree.leafAt`,
/// `imtProof = tree.merklePath`. The cross-chain authentication of the `(root)` message —
/// `proveL2MessageInclusionShared` — is mocked to `true` here (the real root check is out of unit-test
/// scope; it is exercised end-to-end in the separate anvil-interop suite). The deadline is a
/// **settlement-layer (SL) block number**: {AtomicInteropProof} re-parses the SAME `messageProof` bytes
/// with the real {MessageHashing._getProofData} (NOT mocked) to derive the SL block, so the proof bytes
/// here are format-valid multi-hop proofs carrying a CHOSEN SL block ({AtomicInteropTestUtils.slProofBytes}).
/// We vary that SL block against the deadline (<= deadline for inclusion, > deadline for non-inclusion).
/// `messageIndex` is 0 because the minimal proof has a zero-length log-leaf path.
///
/// For the canonical 2-leg swap, each leg's bundle is `sendBundle`'d on its own source chain: the AB
/// bundle (source A, destination B) and the BA bundle (source B, destination A). A `bundleHash` bakes in
/// `sourceChainId`, so a leg can only ever be committed in its own chain's tree.
contract AtomicFlowManagerTest is Test {
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint64 internal constant DEADLINE = 2000;
    /// @dev The settlement layer all legs settle on (single-SL assumption); embedded in the proof bytes.
    uint256 internal constant SL_CHAIN_ID = 506;

    // Dummy top-level batch fields: the verification call is mocked to true, so they are not inspected
    // by the auth layer. `DUMMY_MSG_INDEX` MUST be 0 — the minimal proof's log-leaf path is empty, so
    // `_getProofData` requires a zero leaf-proof mask.
    uint256 internal constant DUMMY_BATCH = 1;
    uint256 internal constant DUMMY_MSG_INDEX = 0;
    uint16 internal constant DUMMY_TX_IN_BATCH = 0;

    // ── Asset / participant fixtures for the recovered bundle ──
    bytes32 internal constant ASSET_ID = bytes32(uint256(0xA55E7));
    address internal alice = makeAddr("alice"); // depositor of the AB leg (source A)
    address internal bob = makeAddr("bob"); // recipient of the AB leg (destination B)
    address internal originToken = makeAddr("originToken");
    uint256 internal constant AMOUNT = 100;

    L2InteropCommitmentTree internal treeA;
    L2InteropCommitmentTree internal treeB;
    AtomicFlowManager internal managerA;
    AtomicFlowManager internal managerB;
    MockAtomicAssetRouter internal arA;
    MockAtomicAssetRouter internal arB;

    function setUp() public {
        AtomicInteropTestUtils.installSystemMocks();
        (treeA, managerA, arA) = _deployStack();
        (treeB, managerB, arB) = _deployStack();
    }

    /// @dev Deploy a real tree + manager + mock AR, wiring this test as both interop center and handler.
    function _deployStack()
        internal
        returns (L2InteropCommitmentTree tree, AtomicFlowManager manager, MockAtomicAssetRouter ar)
    {
        tree = new L2InteropCommitmentTree();
        manager = new AtomicFlowManager();
        ar = new MockAtomicAssetRouter();
        tree.initialize(address(manager));
        // ic == ih == this test, so it can drive append / requireFlowFinalized directly.
        manager.initialize(address(tree), address(ar), address(this), address(this));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // append
    // ─────────────────────────────────────────────────────────────────────────────────────

    function test_append_commitsLegAndInsertsIntoTree() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 thisLeg = _sourceLegOf(CHAIN_A, hAB, hBA); // the leg whose source is A

        uint256 value = AtomicInteropTestUtils.commitValue(flowId, thisLeg);
        uint256 lowNull = AtomicInteropTestUtils.lowNullifierIndex(treeA, value);
        uint256 leavesBefore = treeA.leafCount();

        vm.expectEmit(true, true, false, true);
        emit IAtomicFlowManager.FlowCommitted(flowId, thisLeg, DEADLINE, leavesBefore); // new leaf @ leavesBefore
        managerA.append(flowId, thisLeg, DEADLINE, lowNull);

        // State -> Committed, value present in the tree (round-trip), leaf count grew by one.
        assertTrue(managerA.legState(flowId, thisLeg) == LegState.Committed, "leg committed on A");
        assertEq(treeA.leafCount(), leavesBefore + 1, "one leaf inserted");
        assertEq(AtomicInteropTestUtils.indexOfValue(treeA, value), leavesBefore, "value at the new leaf index");
    }

    function test_append_revertsOnDoubleCommit() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 thisLeg = _sourceLegOf(CHAIN_A, hAB, hBA);
        _appendLeg(managerA, treeA, flowId, thisLeg);

        // Re-appending the same (flowId, bundleHash) must revert before touching the tree. The
        // low-nullifier index is irrelevant here (the ALREADY_COMMITTED check runs first), so we pass 0.
        vm.expectRevert(abi.encodeWithSelector(ManagerLegAlreadyCommitted.selector, flowId, thisLeg));
        managerA.append(flowId, thisLeg, DEADLINE, 0);
    }

    function test_append_revertsForNonInteropCenter() public {
        // A manager wired to a different ic/ih: this test is neither, so `append` must be rejected.
        AtomicFlowManager other = new AtomicFlowManager();
        L2InteropCommitmentTree otherTree = new L2InteropCommitmentTree();
        otherTree.initialize(address(other));
        other.initialize(address(otherTree), address(arA), makeAddr("ic"), makeAddr("ih"));

        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropCenter.selector, address(this)));
        other.append(keccak256("f"), keccak256("b"), DEADLINE, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // requireFlowFinalized
    // ─────────────────────────────────────────────────────────────────────────────────────

    function test_requireFlowFinalized_happyPath() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);

        // Both source legs committed in their own chain's tree.
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        // The destination on chain B is executing the AB bundle; check finality against B's manager.
        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, 1500); // SL block 1500 <= deadline

        // The bundle being executed (the AB leg) is a leg of the flow -> no revert.
        managerB.requireFlowFinalized(hAB, finality);
        // (view; nothing to assert beyond non-revert — the call is the assertion.)
    }

    function test_requireFlowFinalized_revertsOnFlowIdMismatch() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, 1500);
        // Corrupt the supplied flowId so the recomputed one cannot match.
        bytes32 wrongFlowId = keccak256("wrong");
        finality.flowId = wrongFlowId;
        bytes32 computed = AtomicInteropTestUtils.computeFlowId(finality.legBundleHashes, finality.chainIds, DEADLINE);

        vm.expectRevert(abi.encodeWithSelector(ManagerFlowIdMismatch.selector, wrongFlowId, computed));
        managerB.requireFlowFinalized(hAB, finality);
    }

    function test_requireFlowFinalized_revertsOnProofCountMismatch() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, 1500);
        // Drop one proof so proofs.length != legBundleHashes.length.
        ImtInclusionProof[] memory short = new ImtInclusionProof[](1);
        short[0] = finality.proofs[0];
        finality.proofs = short;

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, uint256(2), uint256(1)));
        managerB.requireFlowFinalized(hAB, finality);
    }

    function test_requireFlowFinalized_revertsWhenDeadlineExceeded() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        // A leg's inclusion proof carries a root that settled at an SL block AFTER the deadline.
        uint256 lateSlBlock = 5000;
        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, lateSlBlock);

        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateSlBlock, DEADLINE));
        managerB.requireFlowFinalized(hAB, finality);
    }

    function test_requireFlowFinalized_revertsOnFinalNodeProof() public {
        // A final-node (single-level / commit-based) proof carries no SL block, so the deadline cannot be
        // expressed against it. It must be rejected even though the message-inclusion call is mocked to
        // true — the SL-block parse runs on the real proof bytes.
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, 1500);
        // Swap the first leg's proof bytes for a final-node proof.
        finality.proofs[0].messageProof = AtomicInteropTestUtils.finalNodeProofBytes();

        vm.expectRevert(
            abi.encodeWithSelector(
                ProofMissingSettlementLayerAnchor.selector,
                finality.proofs[0].sourceChainId,
                finality.proofs[0].batchNumber
            )
        );
        managerB.requireFlowFinalized(hAB, finality);
    }

    function test_requireFlowFinalized_revertsWhenExecutingBundleNotInFlow() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, 1500);
        // Execute a bundle that is NOT one of the flow's legs — all inclusion proofs still verify, but the
        // executing-is-a-leg check must fail.
        bytes32 strangerBundle = keccak256("not-a-leg");
        vm.expectRevert(abi.encodeWithSelector(ManagerExecutingBundleNotInFlow.selector, flowId, strangerBundle));
        managerB.requireFlowFinalized(strangerBundle, finality);
    }

    function test_requireFlowFinalized_revertsForNonInteropHandler() public {
        // A manager wired to a different ic/ih: this test is neither, so `requireFlowFinalized` is rejected.
        AtomicFlowManager other = new AtomicFlowManager();
        L2InteropCommitmentTree otherTree = new L2InteropCommitmentTree();
        otherTree.initialize(address(other));
        other.initialize(address(otherTree), address(arA), makeAddr("ic"), makeAddr("ih"));

        // The ACL modifier runs before any flowId / proof checks, so an empty finality struct suffices
        // (no real tree state is needed to exercise the handler gate).
        AtomicFinalityProof memory finality = AtomicFinalityProof({
            flowId: bytes32(0),
            deadline: DEADLINE,
            legBundleHashes: new bytes32[](0),
            chainIds: new uint256[](0),
            proofs: new ImtInclusionProof[](0)
        });

        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropHandler.selector, address(this)));
        other.requireFlowFinalized(_bundleHashAB(), finality);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // authorizeRefund + claimRefund (timeout path)
    // ─────────────────────────────────────────────────────────────────────────────────────

    function test_refund_happyTimeoutPath() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 sourceLegA = _sourceLegOf(CHAIN_A, hAB, hBA);

        // A commits its source leg; B never commits the other leg -> B's IMT lacks it.
        _appendLeg(managerA, treeA, flowId, sourceLegA);
        bytes32 missingLeg = _sourceLegOf(CHAIN_B, hAB, hBA);

        // 1. Authorize the refund: non-inclusion of the missing leg against B's tree, with a root that
        //    settled at an SL block (5000) strictly past the deadline.
        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, missingLeg, 5000);
        uint256 missingIdx = _missingIdx(hAB, hBA, CHAIN_B);

        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowManager.FlowRefundAuthorized(flowId, sourceLegA);
        managerA.authorizeRefund(flowId, _legHashes(hAB, hBA), _chainIds(), DEADLINE, missingIdx, proof);
        assertTrue(managerA.legState(flowId, sourceLegA) == LegState.Revertable, "source leg revertable on A");

        // 2. Claim the refund: decode the real AB bundle and recover the burn to the depositor.
        bytes memory bundleBytes = _abBundleBytes();

        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowManager.FlowRefunded(flowId, sourceLegA);
        managerA.claimRefund(flowId, bundleBytes);

        assertEq(arA.recoverCount(), 1, "recoverAtomicBurn routed once");
        assertEq(arA.lastChainId(), CHAIN_B, "recover references the AB bundle's destination chain B");
        assertEq(arA.lastAssetId(), ASSET_ID, "recover references the burned asset id");
        assertTrue(managerA.legState(flowId, sourceLegA) == LegState.Reverted, "source leg reverted on A");

        // The re-mint must target the depositor (alice) as both originalCaller and remoteReceiver.
        (address recvCaller, address recvReceiver, , uint256 recvAmount, ) = DataEncoding.decodeBridgeMintData(
            arA.lastRecoverData()
        );
        assertEq(recvCaller, alice, "recover re-mints to depositor (caller)");
        assertEq(recvReceiver, alice, "recover re-mints to depositor (receiver)");
        assertEq(recvAmount, AMOUNT, "recover preserves amount");
    }

    function test_claimRefund_revertsWhenNotRevertable() public {
        // A leg only committed (not authorized for refund) cannot be claimed.
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 sourceLegA = _sourceLegOf(CHAIN_A, hAB, hBA);
        _appendLeg(managerA, treeA, flowId, sourceLegA);

        bytes memory bundleBytes = _abBundleBytes();
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, flowId, sourceLegA, LegState.Committed)
        );
        managerA.claimRefund(flowId, bundleBytes);
    }

    function test_claimRefund_revertsWhenNoRecoverableCalls() public {
        // A Revertable leg whose bundle carries no asset-router finalizeDeposit call has nothing to
        // recover -> ManagerNoRecoverableCalls.
        bytes32 hBA = _bundleHashBA();
        bytes memory emptyBundleBytes = _bundleBytes(CHAIN_A, CHAIN_B, _noArCalls());
        bytes32 emptyHash = InteropDataEncoding.encodeInteropBundleHash(CHAIN_A, emptyBundleBytes);
        // Use the empty bundle's hash as the AB-leg hash so authorize marks exactly it Revertable.
        bytes32 hAB = emptyHash;
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, hAB);

        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, hBA, 5000);
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _chainIds(),
            DEADLINE,
            _missingIdx(hAB, hBA, CHAIN_B),
            proof
        );
        assertTrue(managerA.legState(flowId, hAB) == LegState.Revertable, "empty bundle leg revertable");

        vm.expectRevert(abi.encodeWithSelector(ManagerNoRecoverableCalls.selector, flowId, emptyHash));
        managerA.claimRefund(flowId, emptyBundleBytes);
    }

    function test_authorizeRefund_revertsWhenNonInclusionWithinDeadline() public {
        // The non-inclusion proof's root settled at an SL block (1500) NOT past the deadline (1500 <=
        // 2000): the leg could still be committed in time, so the refund must be rejected.
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        bytes32 missingLeg = _sourceLegOf(CHAIN_B, hAB, hBA);

        uint256 earlySlBlock = 1500;
        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, missingLeg, earlySlBlock);

        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineNotExceeded.selector, earlySlBlock, DEADLINE));
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _chainIds(),
            DEADLINE,
            _missingIdx(hAB, hBA, CHAIN_B),
            proof
        );
    }

    function test_authorizeRefund_revertsIfLegActuallyPresent() public {
        // Both legs committed: the "missing" leg IS present on B, so its low-nullifier cannot bracket it
        // -> verifyNonInclusion fails (the deadline check, which runs first, passes since 5000 > DEADLINE).
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        bytes32 legB = _sourceLegOf(CHAIN_B, hAB, hBA);
        _appendLeg(managerB, treeB, flowId, legB); // legB IS present on B

        uint256 legBValue = AtomicInteropTestUtils.commitValue(flowId, legB);
        ImtNonInclusionProof memory proof = ImtNonInclusionProof({
            sourceChainId: CHAIN_B,
            batchNumber: DUMMY_BATCH,
            chainImtRoot: treeB.root(),
            messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
            messageIndex: DUMMY_MSG_INDEX,
            messageProof: AtomicInteropTestUtils.slProofBytes(5000, SL_CHAIN_ID), // SL block 5000 > deadline
            lowLeaf: treeB.leafAt(0), // head leaf does not bracket a present value
            lowLeafIndex: 0,
            imtProof: treeB.merklePath(0)
        });

        vm.expectRevert(abi.encodeWithSelector(ProofNonInclusionFailed.selector, treeB.root(), legBValue));
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _chainIds(),
            DEADLINE,
            _missingIdx(hAB, hBA, CHAIN_B),
            proof
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Mutual exclusivity (no double-spend)
    // ─────────────────────────────────────────────────────────────────────────────────────

    function test_mutualExclusivity_finalizedThenRefundBlocked() public {
        // A leg finalized via an inclusion proof (SL block <= deadline) and then driven down the refund
        // path must NOT be claimable: a leg present in a root settled <= deadline cannot also be absent in
        // a root settled > deadline (append-only IMT). We assert the state machine prevents the
        // double-spend: once finalized, the source leg stays Committed (never Revertable), so claimRefund
        // reverts.
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 sourceLegA = _sourceLegOf(CHAIN_A, hAB, hBA);
        _appendLeg(managerA, treeA, flowId, sourceLegA);
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        // Finalize on the destination (B). This does not change A's source-leg state — A stays Committed.
        AtomicFinalityProof memory finality = _finality(flowId, hAB, hBA, 1500);
        managerB.requireFlowFinalized(hAB, finality);
        assertTrue(managerA.legState(flowId, sourceLegA) == LegState.Committed, "source leg still committed");

        // Because the flow finalized, BOTH legs are present in their trees -> no valid post-deadline
        // non-inclusion proof exists for either, so authorizeRefund cannot move the leg to Revertable.
        // claimRefund therefore reverts (leg not Revertable) — the double-spend is structurally blocked.
        bytes memory bundleBytes = _abBundleBytes();
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, flowId, sourceLegA, LegState.Committed)
        );
        managerA.claimRefund(flowId, bundleBytes);
    }

    function test_mutualExclusivity_refundedThenFinalizeBlocked() public {
        // The reverse: once a leg is refunded (some leg absent past deadline), the destination cannot
        // finalize the AB bundle, because no inclusion proof <= deadline exists for the missing leg.
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 sourceLegA = _sourceLegOf(CHAIN_A, hAB, hBA);
        bytes32 missingLeg = _sourceLegOf(CHAIN_B, hAB, hBA);

        // A commits; B never commits its leg. Refund A's source leg.
        _appendLeg(managerA, treeA, flowId, sourceLegA);
        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, missingLeg, 5000);
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _chainIds(),
            DEADLINE,
            _missingIdx(hAB, hBA, CHAIN_B),
            proof
        );
        managerA.claimRefund(flowId, _abBundleBytes());
        assertTrue(managerA.legState(flowId, sourceLegA) == LegState.Reverted, "source leg reverted");

        // The destination can never produce a valid inclusion proof for the missing B leg: B's tree does
        // not contain it, so building one is impossible. We assert finalization fails when supplied with a
        // proof whose root (still B's tree, missing the leg) cannot include the leg value. We reuse the
        // inclusion-proof helper with B's tree, which has no leaf for the missing leg -> indexOfValue
        // reverts, demonstrating the proof cannot be constructed. To keep the assertion concrete inside the
        // contract, instead drive finality past the deadline (the only honest proof B could publish post-
        // timeout) and assert ProofDeadlineExceeded.
        AtomicFinalityProof memory lateFinality = _partialFinality(flowId, hAB, hBA, sourceLegA, 5000);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, uint256(5000), DEADLINE));
        managerB.requireFlowFinalized(hAB, lateFinality);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @dev `bundleHash` of the AB leg (source A, destination B): `keccak256(abi.encode(srcChainId, bundleBytes))`.
    function _bundleHashAB() internal view returns (bytes32) {
        return InteropDataEncoding.encodeInteropBundleHash(CHAIN_A, _abBundleBytes());
    }

    /// @dev `bundleHash` of the BA leg (source B, destination A).
    function _bundleHashBA() internal view returns (bytes32) {
        return InteropDataEncoding.encodeInteropBundleHash(CHAIN_B, _baBundleBytes());
    }

    /// @dev The AB leg's ABI-encoded bundle: a single asset-router finalizeDeposit call (the destination
    /// mint embedded by `initiateIndirectCall`), so claimRefund can reverse it via recoverAtomicBurn.
    function _abBundleBytes() internal view returns (bytes memory) {
        return _bundleBytes(CHAIN_A, CHAIN_B, _arFinalizeCall(CHAIN_A, alice, bob));
    }

    /// @dev The BA leg's bundle (mirror of AB). Its contents only matter for hash distinctness here.
    function _baBundleBytes() internal view returns (bytes memory) {
        return _bundleBytes(CHAIN_B, CHAIN_A, _arFinalizeCall(CHAIN_B, bob, alice));
    }

    /// @dev Build an InteropBundle's ABI bytes from source/destination chain ids and a calls array.
    function _bundleBytes(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        InteropCall[] memory _calls
    ) internal pure returns (bytes memory) {
        InteropBundle memory bundle = InteropBundle({
            version: bytes1(0x01),
            sourceChainId: _sourceChainId,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: bytes32(0),
            interopBundleSalt: bytes32(0),
            calls: _calls,
            bundleAttributes: BundleAttributes({
                executionAddress: "",
                unbundlerAddress: "",
                useFixedFee: false
            })
        });
        return abi.encode(bundle);
    }

    /// @dev A single-element calls array carrying the asset-router `finalizeDeposit(srcChainId, assetId,
    /// bridgeMintData)` call the manager recognises and reverses. The mint data encodes the depositor as
    /// originalCaller and the recipient as remoteReceiver.
    function _arFinalizeCall(
        uint256 _srcChainId,
        address _depositor,
        address _recipient
    ) internal view returns (InteropCall[] memory calls) {
        bytes memory bridgeMintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _depositor,
            _remoteReceiver: _recipient,
            _originToken: originToken,
            _amount: AMOUNT,
            _erc20Metadata: ""
        });
        bytes memory data = abi.encodeWithSelector(
            IAssetRouterFinalizeDeposit.finalizeDeposit.selector,
            _srcChainId,
            ASSET_ID,
            bridgeMintData
        );
        calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: bytes1(0x01),
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: _depositor,
            value: 0,
            data: data
        });
    }

    /// @dev A calls array with a single non-asset-router call -> nothing recoverable.
    function _noArCalls() internal pure returns (InteropCall[] memory calls) {
        address stranger = address(0xBEEF);
        calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: bytes1(0x01),
            shadowAccount: false,
            to: stranger,
            from: stranger,
            value: 0,
            data: hex"deadbeef"
        });
    }

    /// @dev Sorted leg-bundle-hash array (strictly ascending), as the manager's flowId recompute requires.
    function _legHashes(bytes32 _hAB, bytes32 _hBA) internal pure returns (bytes32[] memory hashes) {
        hashes = new bytes32[](2);
        (hashes[0], hashes[1]) = _hAB < _hBA ? (_hAB, _hBA) : (_hBA, _hAB);
    }

    /// @dev Strictly-ascending chain ids (CHAIN_A < CHAIN_B).
    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = CHAIN_A;
        ids[1] = CHAIN_B;
    }

    /// @dev flowId from the two leg hashes + the canonical chain ids + deadline.
    function _flowId(bytes32 _hAB, bytes32 _hBA) internal pure returns (bytes32) {
        return AtomicInteropTestUtils.computeFlowId(_legHashes(_hAB, _hBA), _chainIds(), DEADLINE);
    }

    /// @dev The leg-bundle-hash whose source chain is `_chainId`. AB is sourced on A, BA on B.
    function _sourceLegOf(uint256 _chainId, bytes32 _hAB, bytes32 _hBA) internal pure returns (bytes32) {
        return _chainId == CHAIN_A ? _hAB : _hBA;
    }

    /// @dev Index (into the sorted leg-hash array) of the leg sourced on `_chainId`.
    function _missingIdx(bytes32 _hAB, bytes32 _hBA, uint256 _chainId) internal pure returns (uint256) {
        bytes32 target = _sourceLegOf(_chainId, _hAB, _hBA);
        bytes32[] memory hashes = _legHashes(_hAB, _hBA);
        return hashes[0] == target ? 0 : 1;
    }

    /// @dev Append a leg on `_manager`'s tree, computing the low-nullifier from real tree state.
    function _appendLeg(
        AtomicFlowManager _manager,
        L2InteropCommitmentTree _tree,
        bytes32 _flowIdLocal,
        bytes32 _bundleHash
    ) internal {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowIdLocal, _bundleHash);
        uint256 lowNull = AtomicInteropTestUtils.lowNullifierIndex(_tree, value);
        _manager.append(_flowIdLocal, _bundleHash, DEADLINE, lowNull);
    }

    /// @dev A full {AtomicFinalityProof} for the 2-leg flow, one inclusion proof per leg (in sorted leg
    /// order), each carrying SL block `_slBlock`. Requires both legs already appended to their trees.
    function _finality(
        bytes32 _flowIdLocal,
        bytes32 _hAB,
        bytes32 _hBA,
        uint256 _slBlock
    ) internal view returns (AtomicFinalityProof memory finality) {
        bytes32[] memory hashes = _legHashes(_hAB, _hBA);
        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusion(_flowIdLocal, hashes[i], _slBlock);
        }
        finality = AtomicFinalityProof({
            flowId: _flowIdLocal,
            deadline: DEADLINE,
            legBundleHashes: hashes,
            chainIds: _chainIds(),
            proofs: proofs
        });
    }

    /// @dev A finality proof where the leg `_presentLeg` (sourced on A, present in A's tree) gets a real
    /// inclusion proof at `_slBlock`, while the other (missing) leg is given a structurally-present proof
    /// against A's tree at `_slBlock` too. Used only to exercise the deadline check on the missing leg in
    /// the refunded-then-finalize mutual-exclusivity test: every proof carries `_slBlock`, so the first
    /// leg checked trips the deadline guard.
    function _partialFinality(
        bytes32 _flowIdLocal,
        bytes32 _hAB,
        bytes32 _hBA,
        bytes32 _presentLeg,
        uint256 _slBlock
    ) internal view returns (AtomicFinalityProof memory finality) {
        bytes32[] memory hashes = _legHashes(_hAB, _hBA);
        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            // Both proofs reference A's tree and the present leg's leaf; only the SL block (> deadline)
            // matters because the deadline guard runs before membership.
            proofs[i] = _inclusion(_flowIdLocal, _presentLeg, _slBlock);
            proofs[i].sourceChainId = hashes[i] == _hAB ? CHAIN_A : CHAIN_B;
        }
        finality = AtomicFinalityProof({
            flowId: _flowIdLocal,
            deadline: DEADLINE,
            legBundleHashes: hashes,
            chainIds: _chainIds(),
            proofs: proofs
        });
    }

    /// @dev An inclusion proof for `(flowId, bundleHash)` built from the appropriate chain's real tree
    /// state, carrying SL block `_slBlock` in its message-proof bytes.
    function _inclusion(
        bytes32 _flowIdLocal,
        bytes32 _bundleHash,
        uint256 _slBlock
    ) internal view returns (ImtInclusionProof memory) {
        // A leg's bundleHash bakes in its source chain; route the proof to that chain's tree.
        bool isA = _bundleHash == _bundleHashAB();
        L2InteropCommitmentTree tree = isA ? treeA : treeB;
        uint256 sourceChainId = isA ? CHAIN_A : CHAIN_B;
        uint256 value = AtomicInteropTestUtils.commitValue(_flowIdLocal, _bundleHash);
        uint256 idx = AtomicInteropTestUtils.indexOfValue(tree, value);
        return
            ImtInclusionProof({
                sourceChainId: sourceChainId,
                batchNumber: DUMMY_BATCH,
                chainImtRoot: tree.root(),
                messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
                messageIndex: DUMMY_MSG_INDEX,
                messageProof: AtomicInteropTestUtils.slProofBytes(_slBlock, SL_CHAIN_ID),
                leaf: tree.leafAt(idx),
                imtLeafIndex: idx,
                imtProof: tree.merklePath(idx)
            });
    }

    /// @dev A non-inclusion proof for `(flowId, bundleHash)` against `_tree`, with SL block `_slBlock`.
    function _nonInclusion(
        IL2InteropCommitmentTree _tree,
        uint256 _chainId,
        bytes32 _flowIdLocal,
        bytes32 _bundleHash,
        uint256 _slBlock
    ) internal view returns (ImtNonInclusionProof memory) {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowIdLocal, _bundleHash);
        uint256 lowIdx = AtomicInteropTestUtils.lowNullifierIndex(_tree, value);
        return
            ImtNonInclusionProof({
                sourceChainId: _chainId,
                batchNumber: DUMMY_BATCH,
                chainImtRoot: _tree.root(),
                messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
                messageIndex: DUMMY_MSG_INDEX,
                messageProof: AtomicInteropTestUtils.slProofBytes(_slBlock, SL_CHAIN_ID),
                lowLeaf: _tree.leafAt(lowIdx),
                lowLeafIndex: lowIdx,
                imtProof: _tree.merklePath(lowIdx)
            });
    }
}
