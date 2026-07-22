// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlow, AtomicFlowPreimage, ImtProof, LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerFlowIdMismatch,
    ManagerLegNotRevertable,
    ProofSourceChainMismatch,
    ProofImtRootInclusionFailed
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {BundleAttributes, INTEROP_BUNDLE_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers the refund path's guards in `AtomicFlowManager` — `authorizeRefund`'s proof and
/// binding checks and `claimRefund`'s leg state machine. The load-bearing property: a refund can only
/// be authorized by a valid absence proof bound to the missing leg's DECLARED source chain (without
/// that binding, a commit value — which exists only in its own chain's tree — is trivially absent
/// from any other chain's tree, so a finalized leg could be force-refunded: the double-mint), and
/// only `Committed` legs flip to `Revertable` / only `Revertable` legs can be claimed.
///
/// Setup mirrors `AtomicFlowManagerAppend.t.sol`: the manager and the commitment tree run at their
/// canonical predeploy addresses and legs are committed through the real `append` path (pranked as
/// the canonical InteropCenter). The flow is all-local (every leg declares this chain), so no
/// Bridgehub registry is consulted at all. Absence-proof fixtures come from
/// {AtomicInteropProofBuilder} — real IMT non-inclusion data and a real seeded
/// {L2InteropRootStorage}; the only mock is the separately-tested cross-chain leaf verifier. The
/// happy authorize+claim flow with real fund recovery is covered end-to-end by
/// `L2AtomicInteropSendRefundTestAbstract`; recovery-call provenance by `AtomicRecoveryForgery.t.sol`.
contract AtomicFlowManagerRefundTest is AtomicInteropProofBuilder {
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant REMOTE_BATCH_NUMBER = 7;
    uint256 internal constant SL_BLOCK = 300;

    AtomicFlowManager internal manager;

    AtomicFlowPreimage internal preimage;
    bytes32 internal flowId;
    /// @dev The committed leg: hash of a real encodable bundle (so `claimRefund` can re-derive it).
    bytes32 internal committedLeg;
    bytes internal committedLegBundleBytes;
    /// @dev The missing leg: never committed anywhere.
    bytes32 internal missingLeg;
    uint256 internal missingLegIndex;

    function setUp() public {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        deployCodeTo("L2InteropCommitmentTree.sol:L2InteropCommitmentTree", L2_INTEROP_COMMITMENT_TREE_ADDR);
        manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(SETTLEMENT_LAYER_CHAIN_ID);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).initL2();

        // Builder fixtures: the oracle tree (a fresh IMT that never holds either commit value — it
        // models the missing leg's source-chain state) and the real interop-root storage, seeded with
        // a post-deadline settlement-layer root through the production entry point.
        _setUpAtomicFixtures();
        _mockVerifier(true);
        _seedSettlementLayerInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 1);

        // The committed leg must hash from real bundle bytes (claimRefund re-derives it); the missing
        // leg is a hash no chain ever commits.
        committedLegBundleBytes = abi.encode(_minimalBundle());
        committedLeg = InteropDataEncoding.encodeInteropBundleHash(committedLegBundleBytes);
        missingLeg = keccak256("never committed leg");

        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legSourceChainIds = new uint256[](2);
        (uint256 committedIdx, uint256 missingIdx) = committedLeg < missingLeg ? (0, 1) : (1, 0);
        preimage.legBundleHashes[committedIdx] = committedLeg;
        preimage.legBundleHashes[missingIdx] = missingLeg;
        // All-local flow: both legs declare this chain, so append consults no Bridgehub registry.
        preimage.legSourceChainIds[committedIdx] = block.chainid;
        preimage.legSourceChainIds[missingIdx] = block.chainid;
        missingLegIndex = missingIdx;
        flowId = keccak256(abi.encode(preimage));

        // Commit the real leg through the production send-side path.
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(committedLeg, 0, preimage);
    }

    /// @dev A minimal well-formed bundle for the committed leg. Its call content is irrelevant here:
    /// every claim in this file is rejected by the leg state machine before recovery is attempted
    /// (the recovery mechanics have their own suites, see the contract header).
    function _minimalBundle() internal view returns (InteropBundle memory bundle) {
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: 777,
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256("refund state machine salt"),
            calls: new InteropCall[](0),
            bundleAttributes: BundleAttributes({
                executionAddress: bytes(""),
                unbundlerAddress: bytes(""),
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
    }

    /// @dev A genuine absence proof for the missing leg: real non-inclusion data from the oracle
    /// tree (late-batch / begin-root branch), declared on the missing leg's source chain.
    function _validAbsence() internal view returns (ImtProof memory) {
        return
            _nonInclusionProof(
                block.chainid,
                REMOTE_BATCH_NUMBER,
                _commitValue(flowId, missingLeg),
                SETTLEMENT_LAYER_CHAIN_ID,
                SL_BLOCK,
                uint256(DEADLINE) + 1
            );
    }

    function _flow() internal view returns (AtomicFlow memory) {
        return AtomicFlow({flowId: flowId, preimage: preimage});
    }

    // ============ authorizeRefund ============

    /// @notice A valid timeout authorization flips exactly this chain's `Committed` legs to
    /// `Revertable` — the missing (never-committed) leg has no state here and MUST stay `Unset`;
    /// flipping it would fabricate a claimable leg out of thin air.
    function test_authorizeRefund_MarksOnlyCommittedLegs() public {
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(flowId, committedLeg);
        manager.authorizeRefund(_flow(), missingLegIndex, _validAbsence());

        assertEq(
            uint256(manager.legState(flowId, committedLeg)),
            uint256(LegState.Revertable),
            "committed leg must become Revertable"
        );
        assertEq(
            uint256(manager.legState(flowId, missingLeg)),
            uint256(LegState.Unset),
            "never-committed leg must stay Unset"
        );
    }

    /// @notice The transition applies to EVERY locally committed leg, not just one: in a three-leg
    /// flow with two legs committed on this chain and one missing, a single authorization flips both
    /// committed legs to `Revertable` — with exactly one `FlowRefundAuthorized` event each — while
    /// the missing leg stays `Unset`.
    function test_authorizeRefund_MarksAllLocalCommittedLegs() public {
        // A fresh all-local three-leg flow (independent of the setUp fixture): two committable legs
        // plus one that is never committed anywhere.
        bytes32[3] memory unsorted = [
            keccak256("multi leg A"),
            keccak256("multi leg B"),
            keccak256("multi missing leg")
        ];
        bytes32 missingLegHash = unsorted[2];
        // Canonical (strictly ascending) leg order, sources positionally all-local.
        AtomicFlowPreimage memory multiPreimage;
        multiPreimage.deadline = DEADLINE;
        multiPreimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        multiPreimage.legBundleHashes = new bytes32[](3);
        multiPreimage.legSourceChainIds = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            multiPreimage.legBundleHashes[i] = unsorted[i];
            multiPreimage.legSourceChainIds[i] = block.chainid;
        }
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (multiPreimage.legBundleHashes[j] < multiPreimage.legBundleHashes[i]) {
                    (multiPreimage.legBundleHashes[i], multiPreimage.legBundleHashes[j]) = (
                        multiPreimage.legBundleHashes[j],
                        multiPreimage.legBundleHashes[i]
                    );
                }
            }
        }
        bytes32 multiFlowId = keccak256(abi.encode(multiPreimage));
        uint256 multiMissingIndex;
        for (uint256 i = 0; i < 3; ++i) {
            if (multiPreimage.legBundleHashes[i] == missingLegHash) {
                multiMissingIndex = i;
            }
        }

        // Commit BOTH non-missing legs through the production send-side path.
        for (uint256 i = 0; i < 3; ++i) {
            if (i == multiMissingIndex) {
                continue;
            }
            vm.prank(L2_INTEROP_CENTER_ADDR);
            manager.append(multiPreimage.legBundleHashes[i], 0, multiPreimage);
        }

        ImtProof memory absence = _nonInclusionProof(
            block.chainid,
            REMOTE_BATCH_NUMBER,
            _commitValue(multiFlowId, missingLegHash),
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );

        vm.recordLogs();
        manager.authorizeRefund(AtomicFlow({flowId: multiFlowId, preimage: multiPreimage}), multiMissingIndex, absence);

        // Exactly one FlowRefundAuthorized per committed leg — no more, no fewer.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 authorizedEvents = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IAtomicFlowManager.FlowRefundAuthorized.selector) {
                ++authorizedEvents;
                assertEq(logs[i].topics[1], multiFlowId, "event must carry the flow id");
            }
        }
        assertEq(authorizedEvents, 2, "exactly the two committed legs must be authorized");

        for (uint256 i = 0; i < 3; ++i) {
            if (i == multiMissingIndex) {
                assertEq(
                    uint256(manager.legState(multiFlowId, multiPreimage.legBundleHashes[i])),
                    uint256(LegState.Unset),
                    "the missing leg must stay Unset"
                );
            } else {
                assertEq(
                    uint256(manager.legState(multiFlowId, multiPreimage.legBundleHashes[i])),
                    uint256(LegState.Revertable),
                    "every locally committed leg must become Revertable"
                );
            }
        }
    }

    /// @notice The double-mint guard: the absence proof must be bound to the missing leg's DECLARED
    /// source chain. A proof against any other chain's tree is rejected before verification — a
    /// commit value exists only in its own chain's tree and is trivially absent elsewhere.
    function test_RevertWhen_AbsenceSourceChainMismatch() public {
        ImtProof memory absence = _validAbsence();
        uint256 unrelatedChainId = 999;
        absence.sourceChainId = unrelatedChainId;

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, block.chainid, unrelatedChainId));
        manager.authorizeRefund(_flow(), missingLegIndex, absence);
    }

    /// @notice A `flowId` that does not match the canonicalized preimage hash is rejected: the
    /// absence proof targets a commit value derived from the CLAIMED id, so a mismatch would let the
    /// prover pick which flow's legs get flipped.
    function test_RevertWhen_FlowIdMismatch() public {
        AtomicFlow memory flow = _flow();
        ImtProof memory absence = _validAbsence();
        bytes32 wrongFlowId = keccak256("wrong flow id");
        flow.flowId = wrongFlowId;

        vm.expectRevert(abi.encodeWithSelector(ManagerFlowIdMismatch.selector, wrongFlowId, flowId));
        manager.authorizeRefund(flow, missingLegIndex, absence);
    }

    /// @notice No state is touched unless the absence proof actually VERIFIES: a proof whose IMT
    /// root fails cross-chain authentication reverts the authorization and every leg keeps its state.
    function test_RevertWhen_AbsenceProofNotAuthenticated() public {
        ImtProof memory absence = _validAbsence();
        _mockVerifier(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProofImtRootInclusionFailed.selector,
                block.chainid,
                REMOTE_BATCH_NUMBER,
                absence.chainImtRoot
            )
        );
        manager.authorizeRefund(_flow(), missingLegIndex, absence);

        assertEq(
            uint256(manager.legState(flowId, committedLeg)),
            uint256(LegState.Committed),
            "a failed authorization must leave the committed leg untouched"
        );
    }

    // ============ claimRefund state machine ============

    /// @notice A leg that is merely `Committed` (no timeout authorized) cannot be claimed: the claim
    /// gate is the ONLY thing standing between a live, finalizable leg and a unilateral refund.
    function test_RevertWhen_ClaimWithoutAuthorization() public {
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, flowId, committedLeg, LegState.Committed)
        );
        manager.claimRefund(flowId, committedLegBundleBytes);
    }

    /// @notice A bundle with no committed state at all (`Unset`) cannot be claimed.
    function test_RevertWhen_ClaimUnknownLeg() public {
        bytes32 unknownFlowId = keccak256("unknown flow");
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, unknownFlowId, committedLeg, LegState.Unset)
        );
        manager.claimRefund(unknownFlowId, committedLegBundleBytes);
    }
}
