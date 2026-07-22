// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {
    AtomicFlow,
    AtomicFlowPreimage,
    AtomicFinalityProof,
    ImtProof
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {
    ManagerFlowIdMismatch,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ProofSourceChainMismatch,
    ProofDeadlineExceeded
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTLeafValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers `AtomicFlowManager.requireFlowFinalized` — the atomicity gate the InteropHandler
/// consults before executing an atomic bundle. The property under test: the gate passes iff EVERY
/// leg of the flow carries a valid in-time inclusion proof bound to the leg's declared source chain,
/// and the executing bundle is itself one of the flow's legs. Skipping any single leg — first, last,
/// or the executing one — must fail the whole gate: that is the atomicity guarantee.
///
/// Proof fixtures come from {AtomicInteropProofBuilder}: the builder's REAL {L2InteropCommitmentTree}
/// serves as the per-source-chain IMT oracle (both legs' commit values are inserted through the real
/// engine; the proofs' membership paths are genuine), and the only mock is the separately-tested
/// cross-chain leaf verifier (`L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared`), driven true so
/// the manager's own checks — not root authentication — decide each test's outcome. The manager is
/// deployed at its canonical predeploy address and called from the pranked canonical InteropHandler,
/// exercising the real `onlyInteropHandler` wiring.
contract AtomicFlowManagerFinalizeTest is AtomicInteropProofBuilder {
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint256 internal constant BATCH_N = 100;
    uint256 internal constant SL_BLOCK = 555;

    AtomicFlowManager internal manager;

    AtomicFlowPreimage internal preimage;
    bytes32 internal flowId;
    /// @dev Aligned with `preimage.legBundleHashes` (ascending); source chains positionally aligned.
    bytes32 internal legFirst;
    bytes32 internal legSecond;
    uint256 internal legFirstIndex;
    uint256 internal legSecondIndex;

    function setUp() public {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(SETTLEMENT_LAYER_CHAIN_ID);

        _setUpAtomicFixtures();
        _mockVerifier(true);

        // A canonical two-leg flow: both legs committed in their source chains' IMTs (one shared
        // oracle tree plays both chains — each proof's chain binding is its `sourceChainId` field,
        // which is exactly what the manager must check against the preimage).
        bytes32 legA = keccak256("finalize leg A");
        bytes32 legB = keccak256("finalize leg B");
        (legFirst, legSecond) = legA < legB ? (legA, legB) : (legB, legA);

        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legBundleHashes[0] = legFirst;
        preimage.legBundleHashes[1] = legSecond;
        preimage.legSourceChainIds = new uint256[](2);
        preimage.legSourceChainIds[0] = CHAIN_A;
        preimage.legSourceChainIds[1] = CHAIN_B;
        flowId = keccak256(abi.encode(preimage));

        legFirstIndex = _insertCommit(_commitValue(flowId, legFirst));
        legSecondIndex = _insertCommit(_commitValue(flowId, legSecond));
    }

    /// @dev A finality proof whose per-leg inclusion proofs are all genuine and in time.
    function _validFinality() internal view returns (AtomicFinalityProof memory finality) {
        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](2);
        finality.proofs[0] = _inclusionProof(
            CHAIN_A,
            BATCH_N,
            legFirstIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        finality.proofs[1] = _inclusionProof(
            CHAIN_B,
            BATCH_N,
            legSecondIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
    }

    function _requireFinalizedAsHandler(bytes32 _executingBundleHash, AtomicFinalityProof memory _finality) internal {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.requireFlowFinalized(_executingBundleHash, _finality);
    }

    // ============ happy path ============

    /// @notice With every leg proven committed in time on its declared source chain, the gate passes
    /// for either executing leg, and each leg's IMT root is authenticated as the batch-END
    /// chain-batch-root leaf of its OWN declared source chain.
    function test_requireFlowFinalized_AllLegsProven() public {
        AtomicFinalityProof memory finality = _validFinality();
        _expectRootAuthentication(finality.proofs[0], ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        _expectRootAuthentication(finality.proofs[1], ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        _requireFinalizedAsHandler(legFirst, finality);

        // The second leg is an equally valid executing bundle for the same flow.
        _requireFinalizedAsHandler(legSecond, _validFinality());
    }

    // ============ reverts ============

    /// @notice A `flowId` that does not match the canonicalized preimage hash is rejected: proofs are
    /// for commit values derived from the CLAIMED id, so accepting a mismatch would unbind the legs.
    function test_RevertWhen_FlowIdMismatch() public {
        AtomicFinalityProof memory finality = _validFinality();
        bytes32 wrongFlowId = keccak256("wrong flow id");
        finality.flow.flowId = wrongFlowId;

        vm.expectRevert(abi.encodeWithSelector(ManagerFlowIdMismatch.selector, wrongFlowId, flowId));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice Exactly one proof per leg: fewer proofs cannot cover every leg, and extra proofs would
    /// silently ignore trailing entries (masking a caller bug).
    function test_RevertWhen_ProofCountMismatch() public {
        AtomicFinalityProof memory finality = _validFinality();
        ImtProof[] memory oneProof = new ImtProof[](1);
        oneProof[0] = finality.proofs[0];
        finality.proofs = oneProof;

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, 2, 1));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice Each proof must be bound to its leg's DECLARED source chain (positional match).
    /// Defense-in-depth on the finalize side, but load-bearing for the symmetric refund path — see
    /// the contract's docs. Swapped proofs (valid on the wrong legs) must not pass.
    function test_RevertWhen_ProofSourceChainMismatch() public {
        AtomicFinalityProof memory finality = _validFinality();
        (finality.proofs[0], finality.proofs[1]) = (finality.proofs[1], finality.proofs[0]);

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, CHAIN_A, CHAIN_B));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice The executing bundle must itself be one of the flow's legs — a fully-proven flow must
    /// not authorize execution of an unrelated bundle.
    function test_RevertWhen_ExecutingBundleNotInFlow() public {
        AtomicFinalityProof memory finality = _validFinality();
        bytes32 strayBundleHash = keccak256("bundle outside the flow");

        vm.expectRevert(abi.encodeWithSelector(ManagerExecutingBundleNotInFlow.selector, flowId, strayBundleHash));
        _requireFinalizedAsHandler(strayBundleHash, finality);
    }

    /// @notice Atomicity: the FIRST leg's proof must actually prove the first leg's commit value.
    /// Presenting another leg's (genuine) membership data in its place fails the whole gate.
    function test_RevertWhen_FirstLegProofDoesNotProveItsCommitValue() public {
        AtomicFinalityProof memory finality = _validFinality();
        // Genuine membership data — but of the SECOND leg's commit value.
        finality.proofs[0].leaf = tree.leafAt(legSecondIndex);
        finality.proofs[0].imtLeafIndex = legSecondIndex;
        finality.proofs[0].imtProof = tree.merklePath(legSecondIndex);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                _commitValue(flowId, legFirst),
                _commitValue(flowId, legSecond)
            )
        );
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice Atomicity: the LAST leg is verified too — a gate that stopped short of the final leg
    /// would finalize a flow with an uncommitted member. (Guards the loop's upper bound.)
    function test_RevertWhen_LastLegProofDoesNotProveItsCommitValue() public {
        AtomicFinalityProof memory finality = _validFinality();
        finality.proofs[1].leaf = tree.leafAt(legFirstIndex);
        finality.proofs[1].imtLeafIndex = legFirstIndex;
        finality.proofs[1].imtProof = tree.merklePath(legFirstIndex);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                _commitValue(flowId, legSecond),
                _commitValue(flowId, legFirst)
            )
        );
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice A leg whose batch settled after the deadline does not finalize the flow, even when
    /// every other leg is in time: the per-leg deadline check flows through the manager path.
    function test_RevertWhen_LegSettledAfterDeadline() public {
        AtomicFinalityProof memory finality = _validFinality();
        uint256 lateTimestamp = uint256(DEADLINE) + 1;
        finality.proofs[1] = _inclusionProof(
            CHAIN_B,
            BATCH_N,
            legSecondIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            lateTimestamp
        );

        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateTimestamp, DEADLINE));
        _requireFinalizedAsHandler(legFirst, finality);
    }
}
