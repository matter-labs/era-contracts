// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicFlowManagerTest} from "./AtomicFlowManager.t.sol";
import {LegState, ImtProof, AtomicTimeoutProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ProofSourceChainMismatch,
    ProofSettlementLayerMismatch,
    ProofDeadlineNotExceeded
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicInteropTestUtils} from "./AtomicInteropTestUtils.sol";

/// @notice Headline atomicity regressions against the FIXED {AtomicFlowManager}, covering the three
/// confirmed double-mint / stuck vectors from the review (conformance vectors V4/V5/V6):
///
///   - BIND-CHAIN (V4): the refund non-inclusion proof's `sourceChainId` used to be unbound, so a
///     leg's commit value — which lives only in its own source chain's IMT, hence is trivially ABSENT
///     from every other chain's tree — could be "proven absent" against a SIBLING chain to force-refund
///     an on-time, FINALIZED leg (double-mint). Fixed by positional `legSourceChainIds` (committed into
///     `flowId`) + the per-leg source-chain binding.
///   - RULE-ADJACENCY (V5): the timeout used a single "absent from any post-deadline root" proof,
///     so an old/empty/genesis root could be authenticated at a later snapshot to force-refund a
///     finalized leg (double-mint). Fixed by the adjacency timeout: absence at the LAST batch with
///     `t <= deadline`, pinned by the consecutive successor with `t > deadline`.
///   - BIND-SL (V6): the proof's settlement layer was discarded, so cross-SL legs had
///     incomparable deadlines. Fixed by committing `settlementLayerChainId` into `flowId` and requiring
///     each proof's resolved `slChainId` to equal it.
///
/// Reuses the canonical 2-chain harness; the cross-chain `(root)` message verification is mocked to
/// `true`, faithfully standing in for the attacker presenting a GENUINE imported interop root (no forgery
/// is needed — the bindings/adjacency, not root authenticity, are what block the attacks).
contract AtomicInteropAtomicityTest is AtomicFlowManagerTest {
    /// @notice V4 (BIND-CHAIN): the cross-chain force-refund of a finalized leg now REVERTS with
    /// {ProofSourceChainMismatch}, and the leg is left untouched (still Committed, never Revertable).
    function test_crossChainForceRefund_reverts() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 legA = _sourceLegOf(CHAIN_A, hAB, hBA); // sourced on A, committed on managerA

        // Both legs commit on time -> the flow is fully finalizable.
        _appendLeg(managerA, treeA, flowId, legA);
        _appendLeg(managerB, treeB, flowId, _sourceLegOf(CHAIN_B, hAB, hBA));

        // The destination (B) finalizes the AB leg. legA is now a FINALIZED leg; A still holds it as
        // Committed (the source manager is not consulted by finalize).
        managerB.requireFlowFinalized(hAB, _finality(flowId, hAB, hBA, 1500)); // t = 1500 <= deadline
        assertTrue(managerA.legState(flowId, legA) == LegState.Committed, "legA committed and finalizable");

        // === Cross-chain force-refund attempt === legA's commit value lives only in CHAIN A's tree, so it
        // is absent from CHAIN B's tree. Build an adjacency timeout for legA against CHAIN B's tree
        // (sourceChainId = CHAIN_B). The fix rejects it: the proof's chain (B) is not legA's declared
        // source (A).
        AtomicTimeoutProof memory timeout = AtomicTimeoutProof({
            absence: _absence(treeB, CHAIN_B, flowId, legA, 1, 1500),
            successor: _successor(treeB, CHAIN_B, 2, 2100)
        });
        uint256 legAIdx = _missingIdx(hAB, hBA, CHAIN_A);

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, CHAIN_A, CHAIN_B));
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _legSourceChainIds(hAB, hBA),
            DEADLINE,
            SL_CHAIN_ID,
            legAIdx,
            timeout
        );

        assertTrue(managerA.legState(flowId, legA) == LegState.Committed, "leg stays committed after rejected refund");
    }

    /// @notice V5 (RULE-ADJACENCY): a stale/genesis-root force-refund is rejected. The attacker
    /// proves absence at an old batch `N` but its consecutive successor `N+1` is still within the deadline
    /// (`t_{N+1} <= deadline`), so `N` is NOT the last in-time batch — the value could still have been
    /// committed between `N` and the deadline. The refund REVERTS with {ProofDeadlineNotExceeded}, so an
    /// old/empty root can no longer force-refund a (potentially finalized) leg.
    function test_staleRootForceRefund_reverts() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 legB = _sourceLegOf(CHAIN_B, hAB, hBA);

        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));

        // Attacker tries to refund using a stale absence batch (batch 1, t_N = 100, near genesis) whose
        // successor (batch 2, t = 1500) is still <= deadline (2000): the adjacency witness is not past the
        // deadline, so it cannot pin batch 1 as the last in-time batch.
        AtomicTimeoutProof memory timeout = AtomicTimeoutProof({
            absence: _absence(treeB, CHAIN_B, flowId, legB, 1, 100),
            successor: _successor(treeB, CHAIN_B, 2, 1500)
        });

        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineNotExceeded.selector, uint256(1500), DEADLINE));
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _legSourceChainIds(hAB, hBA),
            DEADLINE,
            SL_CHAIN_ID,
            _missingIdx(hAB, hBA, CHAIN_B),
            timeout
        );
    }

    /// @notice V6 (BIND-SL): a refund proof whose resolved settlement-layer chain id differs from
    /// the flow's `settlementLayerChainId` REVERTS with {ProofSettlementLayerMismatch}, so cross-SL legs
    /// (with incomparable deadlines) cannot drive a refund.
    function test_crossSettlementLayerProof_reverts() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);

        _appendLeg(managerA, treeA, flowId, _sourceLegOf(CHAIN_A, hAB, hBA));
        bytes32 missingLegB = _sourceLegOf(CHAIN_B, hAB, hBA);

        // Absence proof targets legB's true source chain (B) and is in time, but its root settled on a
        // DIFFERENT settlement layer than the flow's `settlementLayerChainId` (SL_CHAIN_ID).
        uint256 wrongSlChainId = SL_CHAIN_ID + 1;
        uint256 value = AtomicInteropTestUtils.commitValue(flowId, missingLegB);
        uint256 lowIdx = AtomicInteropTestUtils.lowNullifierIndex(treeB, value);
        AtomicTimeoutProof memory timeout = AtomicTimeoutProof({
            absence: ImtProof({
                sourceChainId: CHAIN_B,
                batchNumber: 1,
                chainImtRoot: treeB.root(),
                messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
                messageIndex: DUMMY_MSG_INDEX,
                messageProof: AtomicInteropTestUtils.slProofBytes(DUMMY_SL_BLOCK, wrongSlChainId, 1500),
                leaf: treeB.leafAt(lowIdx),
                imtLeafIndex: lowIdx,
                imtProof: treeB.merklePath(lowIdx)
            }),
            successor: _successor(treeB, CHAIN_B, 2, 2100)
        });

        vm.expectRevert(abi.encodeWithSelector(ProofSettlementLayerMismatch.selector, SL_CHAIN_ID, wrongSlChainId));
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _legSourceChainIds(hAB, hBA),
            DEADLINE,
            SL_CHAIN_ID,
            _missingIdx(hAB, hBA, CHAIN_B),
            timeout
        );
    }

    /// @notice The fixes preserve correctness: a genuine timeout (adjacency proof against the missing
    /// leg's OWN source chain and the flow's SL) still authorizes the refund.
    function test_legitimateTimeoutStillRefunds() public {
        bytes32 hAB = _bundleHashAB();
        bytes32 hBA = _bundleHashBA();
        bytes32 flowId = _flowId(hAB, hBA);
        bytes32 legA = _sourceLegOf(CHAIN_A, hAB, hBA);

        // legA commits on A; legB (sourced on B) never commits -> it is absent from B's tree.
        _appendLeg(managerA, treeA, flowId, legA);
        bytes32 missingLegB = _sourceLegOf(CHAIN_B, hAB, hBA);

        AtomicTimeoutProof memory timeout = _timeout(treeB, CHAIN_B, flowId, missingLegB);
        managerA.authorizeRefund(
            flowId,
            _legHashes(hAB, hBA),
            _legSourceChainIds(hAB, hBA),
            DEADLINE,
            SL_CHAIN_ID,
            _missingIdx(hAB, hBA, CHAIN_B),
            timeout
        );
        assertTrue(managerA.legState(flowId, legA) == LegState.Revertable, "legitimate timeout still refunds");
    }
}
