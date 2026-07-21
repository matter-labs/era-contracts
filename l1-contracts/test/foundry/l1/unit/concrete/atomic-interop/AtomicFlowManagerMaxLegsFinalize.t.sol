// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {
    AtomicFinalityProof,
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {MAX_ATOMIC_FLOW_LEGS} from "contracts/interop/InteropConstants.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Establishes that a flow at exactly {MAX_ATOMIC_FLOW_LEGS} — the largest flow `append`
/// admits — can actually pass `requireFlowFinalized`, and bounds its verification gas. The cap's
/// whole justification is "every admitted flow stays finalizable in one transaction"; without this
/// test, raising the constant (or a cost regression in per-leg verification) could strand admitted
/// flows while the boundary-commit unit test stayed green.
///
/// Proof realism: every leg's commit value is inserted into a REAL {L2InteropCommitmentTree} and its
/// inclusion proof is assembled from the real tree (leaf, index, Merkle path — all keccak-verified
/// on-chain). The one mocked layer, as everywhere in this suite, is the separately-tested cross-chain
/// leaf verifier (`proveL2LeafInclusionShared`), so the measured gas EXCLUDES the settlement-proof
/// authentication done by that verifier. The budget below is therefore a lower-bound-style guard: it
/// catches per-leg cost growth in everything this module executes itself, not an exact production
/// figure.
contract AtomicFlowManagerMaxLegsFinalizeTest is AtomicInteropProofBuilder {
    uint256 internal constant L1_CHAIN_ID = 5;
    uint256 internal constant SOURCE_CHAIN_ID = 777;
    uint256 internal constant BATCH_NUMBER = 1;
    uint256 internal constant SL_BLOCK = 201;

    /// @dev Generous headroom over the measured max-legs verification cost (the whole test, inserts
    /// included, measures ~3.5M gas at cap 16, so verification alone is comfortably below that),
    /// but far below the 30M L1 block gas / 80M default L2 batch limits the cap exists to respect.
    /// If this assertion starts failing, per-leg verification got materially more expensive (or the
    /// cap was raised) — revisit {MAX_ATOMIC_FLOW_LEGS} before loosening the budget.
    uint256 internal constant MAX_LEGS_FINALITY_GAS_BUDGET = 10_000_000;

    AtomicFlowManager internal manager;

    function setUp() public {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(L1_CHAIN_ID);
        _setUpAtomicFixtures();
        _mockVerifier(true);
    }

    /// @notice A flow with exactly {MAX_ATOMIC_FLOW_LEGS} legs — every leg committed in the (real)
    /// source IMT — passes `requireFlowFinalized` within the gas budget.
    function test_requireFlowFinalized_MaxLegsFlowVerifiesWithinBudget() public {
        // Independent pin of the admission boundary: raising the cap must consciously revisit this
        // test's budget (and the real settlement-proof calldata cost), not silently inherit it.
        assertEq(MAX_ATOMIC_FLOW_LEGS, 16, "cap changed: re-derive the finalization gas/calldata budget");

        AtomicFlowPreimage memory preimage;
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](MAX_ATOMIC_FLOW_LEGS);
        preimage.legSourceChainIds = new uint256[](MAX_ATOMIC_FLOW_LEGS);
        for (uint256 i = 0; i < MAX_ATOMIC_FLOW_LEGS; ++i) {
            preimage.legBundleHashes[i] = bytes32(i + 1); // strictly ascending
            preimage.legSourceChainIds[i] = SOURCE_CHAIN_ID;
        }
        bytes32 flowId = keccak256(abi.encode(preimage));

        // Commit every leg into the real tree first; proofs must be assembled afterwards, against
        // the final root.
        uint256[] memory leafIndexes = new uint256[](MAX_ATOMIC_FLOW_LEGS);
        for (uint256 i = 0; i < MAX_ATOMIC_FLOW_LEGS; ++i) {
            leafIndexes[i] = _insertCommit(_commitValue(flowId, preimage.legBundleHashes[i]));
        }
        AtomicFinalityProof memory finality;
        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](MAX_ATOMIC_FLOW_LEGS);
        for (uint256 i = 0; i < MAX_ATOMIC_FLOW_LEGS; ++i) {
            finality.proofs[i] = _inclusionProof({
                _sourceChainId: SOURCE_CHAIN_ID,
                _batchNumber: BATCH_NUMBER,
                _leafIndex: leafIndexes[i],
                _slChainId: L1_CHAIN_ID,
                _slBlock: SL_BLOCK,
                _l1Timestamp: DEADLINE - 1 // settled before the deadline
            });
        }

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        uint256 gasBefore = gasleft();
        manager.requireFlowFinalized(preimage.legBundleHashes[0], finality);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, MAX_LEGS_FINALITY_GAS_BUDGET, "max-legs finalization exceeded its gas budget");
    }
}
