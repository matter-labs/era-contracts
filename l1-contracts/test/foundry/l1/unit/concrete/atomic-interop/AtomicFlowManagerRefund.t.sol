// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof,
    LegState,
    ATOMIC_FLOW_PREIMAGE_VERSION
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerFlowIdMismatch,
    ManagerLegNotRevertable,
    ProofSourceChainMismatch,
    ProofImtRootInclusionFailed
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall
} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers the refund path's guards in `AtomicFlowManager` — `authorizeRefund`'s proof and
/// source-chain binding checks (the anti-double-mint, see {protocol-docs/atomicity/proofs.md#timeout})
/// and `claimRefund`'s leg state machine.
/// @dev Manager + commitment tree run at their canonical predeploys; the committed leg goes through
/// the real `append` (pranked canonical InteropCenter). The MISSING leg declares a remote source
/// (`MISSING_LEG_CHAIN`) so its absence proof runs end-to-end through real aggregation + import +
/// {L2MessageVerification} (see {AtomicInteropProofBuilder}); only the force-failure negative and the
/// intrinsically-local late-commit case stub the leaf verifier. Real fund recovery is covered by
/// `L2AtomicInteropSendRefundTestAbstract` and `AtomicRecoveryForgery.t.sol`.
contract AtomicFlowManagerRefundTest is AtomicInteropProofBuilder {
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant REMOTE_BATCH_NUMBER = 7;
    uint256 internal constant SL_BLOCK = 300;
    /// @dev The missing leg's remote source chain — aggregatable in the settlement-layer MessageRoot
    /// (unlike the local chain), so its absence gets a real, unmocked authentication.
    uint256 internal constant MISSING_LEG_CHAIN = 271;

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

        // Builder fixtures: the oracle tree models the missing leg's source-chain state (it never
        // holds either commit value).
        _setUpAtomicFixtures();

        // The committed leg must hash from real bundle bytes (claimRefund re-derives it); the missing
        // leg is a hash no chain ever commits.
        committedLegBundleBytes = abi.encode(_minimalBundle());
        committedLeg = InteropDataEncoding.encodeInteropBundleHash(committedLegBundleBytes);
        missingLeg = keccak256("never committed leg");

        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legSourceChainIds = new uint256[](2);
        (uint256 committedIdx, uint256 missingIdx) = committedLeg < missingLeg ? (0, 1) : (1, 0);
        preimage.legBundleHashes[committedIdx] = committedLeg;
        preimage.legBundleHashes[missingIdx] = missingLeg;
        // The committed leg is local (append requires the committing bundle's source to be this chain);
        // the missing leg declares a remote source so its absence gets a real MessageRoot aggregation.
        preimage.legSourceChainIds[committedIdx] = block.chainid;
        preimage.legSourceChainIds[missingIdx] = MISSING_LEG_CHAIN;
        missingLegIndex = missingIdx;
        flowId = keccak256(abi.encode(preimage));

        // The remote missing-leg source must look interop-registered to the send-side `append` (a
        // Bridgehub registry lookup, orthogonal to the atomic proof machinery).
        _registerRemoteLegSource(MISSING_LEG_CHAIN);

        // Commit the real leg through the production send-side path.
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(committedLeg, 0, preimage);
    }

    /// @dev Stubs the send-side Bridgehub `baseTokenAssetId` registry so `append` accepts `_chainId` as
    /// a declared remote leg source. This is the only send-side stub; the absence-proof path is real.
    function _registerRemoteLegSource(uint256 _chainId) internal {
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSignature("baseTokenAssetId(uint256)", _chainId),
            abi.encode(keccak256(abi.encode("remote base token asset id", _chainId)))
        );
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

    /// @dev A genuine end-to-end absence proof for the missing leg (begin branch, declared on
    /// `MISSING_LEG_CHAIN`). NOT `view`: real aggregation + import mutate settlement-layer state.
    function _validAbsence() internal returns (ImtProof memory) {
        return _realTimeoutBeginProof(MISSING_LEG_CHAIN, _commitValue(flowId, missingLeg), uint256(DEADLINE) + 1);
    }

    function _flow() internal view returns (AtomicFlow memory) {
        return AtomicFlow({flowId: flowId, preimage: preimage});
    }

    // ============ authorizeRefund ============

    /// @notice The transition applies to EVERY locally committed leg, not just one: in a three-leg
    /// flow with two legs committed on this chain and one missing, a single authorization flips both
    /// committed legs to `Revertable` — with exactly one `FlowRefundAuthorized` event each — while
    /// the missing leg stays `Unset`.
    function test_authorizeRefund_MarksAllLocalCommittedLegs() public {
        // A fresh all-local three-leg flow (independent of the setUp fixture): fixed strictly-ascending
        // leg hashes, with the never-committed missing leg at slot 1 declaring a remote source so its
        // absence can be authenticated against a real aggregation.
        AtomicFlowPreimage memory multiPreimage;
        multiPreimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        multiPreimage.deadline = DEADLINE;
        multiPreimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        multiPreimage.legBundleHashes = new bytes32[](3);
        multiPreimage.legBundleHashes[0] = bytes32(uint256(1));
        multiPreimage.legBundleHashes[1] = bytes32(uint256(2));
        multiPreimage.legBundleHashes[2] = bytes32(uint256(3));
        uint256 multiMissingIndex = 1;
        bytes32 missingLegHash = multiPreimage.legBundleHashes[multiMissingIndex];
        multiPreimage.legSourceChainIds = new uint256[](3);
        multiPreimage.legSourceChainIds[0] = block.chainid;
        multiPreimage.legSourceChainIds[1] = MISSING_LEG_CHAIN;
        multiPreimage.legSourceChainIds[2] = block.chainid;
        bytes32 multiFlowId = keccak256(abi.encode(multiPreimage));

        // Commit BOTH non-missing legs through the production send-side path.
        for (uint256 i = 0; i < 3; ++i) {
            if (i == multiMissingIndex) {
                continue;
            }
            vm.prank(L2_INTEROP_CENTER_ADDR);
            manager.append(multiPreimage.legBundleHashes[i], 0, multiPreimage);
        }

        ImtProof memory absence = _realTimeoutBeginProof(
            MISSING_LEG_CHAIN,
            _commitValue(multiFlowId, missingLegHash),
            uint256(DEADLINE) + 1
        );

        vm.recordLogs();
        manager.authorizeRefund(AtomicFlow({flowId: multiFlowId, preimage: multiPreimage}), multiMissingIndex, absence);

        // Each committed bundle hash must be authorized EXACTLY ONCE, emitted BY the manager, with the
        // correct indexed (flowId, bundleHash) topics — and the missing leg must not be authorized at
        // all. Counting per-hash (not just total) rejects a mutant that emits one leg twice.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 totalAuthorized = 0;
        for (uint256 legIdx = 0; legIdx < 3; ++legIdx) {
            bytes32 legHash = multiPreimage.legBundleHashes[legIdx];
            uint256 perLeg = 0;
            for (uint256 i = 0; i < logs.length; ++i) {
                if (
                    logs[i].emitter == address(manager) &&
                    logs[i].topics[0] == IAtomicFlowManager.FlowRefundAuthorized.selector &&
                    logs[i].topics[1] == multiFlowId &&
                    logs[i].topics[2] == legHash
                ) {
                    ++perLeg;
                }
            }
            totalAuthorized += perLeg;
            assertEq(
                perLeg,
                legIdx == multiMissingIndex ? 0 : 1,
                "each committed leg authorized exactly once, missing leg never"
            );
        }
        assertEq(totalAuthorized, 2, "no FlowRefundAuthorized beyond the two committed legs");

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

    /// @notice A leg that is currently `Committed` remains refundable when an authenticated
    /// post-deadline snapshot proves that it was absent. This pins the case where the committed leg
    /// is itself at `_missingLegIndex`.
    /// @dev Recovery is isolated to a single mock (`recoverAtomicCall`); the real recovery chain is
    /// covered by `AtomicRecoveryForgery.t.sol` and the send/refund integration suite.
    function test_authorizeRefund_CommittedLegAtMissingIndexIsRefundable() public {
        // The late leg carries a recoverable (asset-router) call so `claimRefund` can complete.
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: makeAddr("late leg recipient"),
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: hex"c0ffee"
        });
        InteropBundle memory lateBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: 777, // not L1: recovery rejects L1-destined bundles
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256("late leg salt"),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: bytes(""),
                unbundlerAddress: bytes(""),
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
        bytes memory lateBundleBytes = abi.encode(lateBundle);
        bytes32 lateLeg = InteropDataEncoding.encodeInteropBundleHash(lateBundleBytes);
        bytes32 peerLeg = keccak256("late-flow peer leg");

        // Two-leg all-local flow; the LATE leg is the one whose absence gets proven (_missingLegIndex).
        AtomicFlowPreimage memory latePreimage;
        latePreimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        latePreimage.deadline = DEADLINE;
        latePreimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        latePreimage.legBundleHashes = new bytes32[](2);
        latePreimage.legSourceChainIds = new uint256[](2);
        (uint256 lateIdx, uint256 peerIdx) = lateLeg < peerLeg ? (0, 1) : (1, 0);
        latePreimage.legBundleHashes[lateIdx] = lateLeg;
        latePreimage.legBundleHashes[peerIdx] = peerLeg;
        latePreimage.legSourceChainIds[lateIdx] = block.chainid;
        latePreimage.legSourceChainIds[peerIdx] = block.chainid;
        bytes32 lateFlowId = keccak256(abi.encode(latePreimage));

        // Both legs are committed in current manager state; the proof below authenticates historical
        // absence from a post-deadline batch root.
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(lateLeg, 0, latePreimage);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(peerLeg, 0, latePreimage);
        assertEq(
            uint256(manager.legState(lateFlowId, lateLeg)),
            uint256(LegState.Committed),
            "the late leg is locally Committed before the refund"
        );

        // Intrinsically LOCAL: the proven-absent leg's source is this chain, which the settlement-layer
        // MessageRoot cannot aggregate as remote — so this case (alone) stubs the leaf verifier.
        _mockVerifier(true);
        _seedSettlementLayerInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 1);
        ImtProof memory absence = _nonInclusionProof(
            block.chainid,
            REMOTE_BATCH_NUMBER,
            _commitValue(lateFlowId, lateLeg),
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(lateFlowId, lateLeg);
        manager.authorizeRefund(AtomicFlow({flowId: lateFlowId, preimage: latePreimage}), lateIdx, absence);

        // The load-bearing assertion: the _missingLegIndex leg itself became Revertable.
        assertEq(
            uint256(manager.legState(lateFlowId, lateLeg)),
            uint256(LegState.Revertable),
            "the late leg at _missingLegIndex must become Revertable"
        );

        // ...and it can actually be claimed (recovery isolated to the one mock).
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector),
            abi.encode(true)
        );
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(lateFlowId, lateLeg);
        manager.claimRefund(lateFlowId, lateBundleBytes);
        assertEq(
            uint256(manager.legState(lateFlowId, lateLeg)),
            uint256(LegState.Reverted),
            "the late leg must be claimable to Reverted"
        );
    }

    // NOTE: the out-of-range `_missingLegIndex` guard (`ManagerMissingLegIndexOutOfRange`, checked
    // before the aligned arrays are indexed) is pinned by
    // AtomicFlowManagerInitTest.test_RevertWhen_refundMissingLegIndexOutOfRange — not repeated here.

    /// @notice The double-mint guard: the absence proof must be bound to the missing leg's DECLARED
    /// source chain. A proof against any other chain's tree is rejected before verification — a
    /// commit value exists only in its own chain's tree and is trivially absent elsewhere.
    function test_RevertWhen_AbsenceSourceChainMismatch() public {
        ImtProof memory absence = _validAbsence();
        uint256 unrelatedChainId = 999;
        absence.sourceChainId = unrelatedChainId;

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, MISSING_LEG_CHAIN, unrelatedChainId));
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

    /// @notice A proof whose IMT root fails cross-chain authentication reverts the authorization.
    function test_RevertWhen_AbsenceProofNotAuthenticated() public {
        // The ONE force-failure negative: making the real verifier reject would require corrupting
        // settlement state, so this case alone stubs it false over a fixed-shape blob.
        ImtProof memory absence = _nonInclusionProof(
            MISSING_LEG_CHAIN,
            REMOTE_BATCH_NUMBER,
            _commitValue(flowId, missingLeg),
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        _mockVerifier(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProofImtRootInclusionFailed.selector,
                MISSING_LEG_CHAIN,
                REMOTE_BATCH_NUMBER,
                absence.chainImtRoot
            )
        );
        manager.authorizeRefund(_flow(), missingLegIndex, absence);
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
