// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";
import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";
import {MockRecoveryRouter} from "./AtomicFlowManagerRecover.t.sol";

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
    /// @dev Destination chain of the recovery bundles below: any chain that is not the settlement
    /// layer, since `_recoverBundle` rejects L1-destined bundles outright.
    uint256 internal constant RECOVERY_DEST_CHAIN_ID = 777;
    address internal constant RECOVERY_CALL_TARGET = address(0xCA11);

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
        (manager, ) = _deployAtomicPredeploys(SETTLEMENT_LAYER_CHAIN_ID, true);

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
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
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
        // A fresh three-leg flow (independent of the setUp fixture): two locally committed legs and a
        // never-committed remote leg at slot 1 whose absence is authenticated by real aggregation.
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
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
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

    // ============ multi-call recovery through the real Revertable path ============

    /// @dev Drives `_bundle`'s leg to `Revertable` entirely through production entry points: a fresh
    /// two-leg flow, a real `append` of this bundle's leg (pranked canonical InteropCenter), then a real
    /// `authorizeRefund` against an end-to-end absence proof for the never-committed co-leg. No leg state
    /// is ever written directly (see AGENTS.md on storage overrides).
    /// @dev NOT `view`: aggregation + import mutate settlement-layer state. Consumes
    /// `MISSING_LEG_CHAIN`'s single post-genesis batch, so a test calling this must not also call
    /// {_validAbsence}. `append` must run before the post-deadline root is imported, hence this order.
    function _revertableLegFromBundle(
        InteropBundle memory _bundle
    ) internal returns (bytes32 recoveryFlowId, bytes32 bundleHash, bytes memory bundleBytes) {
        bundleBytes = abi.encode(_bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundleBytes);
        bytes32 coLeg = keccak256("recovery co-leg");

        AtomicFlowPreimage memory recoveryPreimage;
        recoveryPreimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        recoveryPreimage.deadline = DEADLINE;
        recoveryPreimage.settlementLayerChainId = SETTLEMENT_LAYER_CHAIN_ID;
        recoveryPreimage.legBundleHashes = new bytes32[](2);
        recoveryPreimage.legSourceChainIds = new uint256[](2);
        (uint256 localIdx, uint256 coIdx) = bundleHash < coLeg ? (0, 1) : (1, 0);
        recoveryPreimage.legBundleHashes[localIdx] = bundleHash;
        recoveryPreimage.legBundleHashes[coIdx] = coLeg;
        recoveryPreimage.legSourceChainIds[localIdx] = block.chainid;
        recoveryPreimage.legSourceChainIds[coIdx] = MISSING_LEG_CHAIN;
        recoveryFlowId = keccak256(abi.encode(recoveryPreimage));

        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(bundleHash, 0, recoveryPreimage);

        ImtProof memory absence = _realTimeoutBeginProof(
            MISSING_LEG_CHAIN,
            _commitValue(recoveryFlowId, coLeg),
            uint256(DEADLINE) + 1
        );
        manager.authorizeRefund(AtomicFlow({flowId: recoveryFlowId, preimage: recoveryPreimage}), coIdx, absence);
        assertEq(
            uint256(manager.legState(recoveryFlowId, bundleHash)),
            uint256(LegState.Revertable),
            "fixture: the leg must be Revertable through the real authorize path"
        );
    }

    /// @dev The stateful asset-router stand-in at its canonical address (shared with
    /// {AtomicFlowManagerRecoverTest}): unlike `vm.mockCall`, its counters are real storage, so they
    /// roll back with a reverting `claimRefund` — which is what the abort test below proves.
    function _deployMockRecoveryRouter() internal returns (MockRecoveryRouter router) {
        deployCodeTo("AtomicFlowManagerRecover.t.sol:MockRecoveryRouter", L2_ASSET_ROUTER_ADDR);
        router = MockRecoveryRouter(L2_ASSET_ROUTER_ADDR);
    }

    function _recoveryCall(
        address _from,
        uint256 _value,
        bytes memory _data
    ) internal pure returns (InteropCall memory) {
        return
            InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: RECOVERY_CALL_TARGET,
                from: _from,
                value: _value,
                data: _data
            });
    }

    function _recoveryBundle(InteropCall[] memory _calls) internal view returns (InteropBundle memory bundle) {
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: RECOVERY_DEST_CHAIN_ID,
            destinationBaseTokenAssetId: keccak256("recovery destination base token"),
            interopBundleSalt: keccak256("multi-call recovery salt"),
            calls: _calls,
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
        });
    }

    /// @notice If EVERY router-backed recovery returns `false`, nothing is recovered — and the refund
    /// must STILL go through: a bundle with no recoverable funds has nothing to return, but flipping the
    /// leg to `Reverted` is meaningful on its own and must not be blocked (see
    /// {AtomicFlowManager._recoverBundle}). All calls are attempted, no payout occurs, `FlowRefunded` is
    /// emitted, and the leg lands terminal `Reverted` (a further claim is rejected).
    function test_claimRefund_multiCall_allRouterFalseSucceedsWithoutPayout() public {
        MockRecoveryRouter router = _deployMockRecoveryRouter();
        router.scriptReturnsFalse(hex"1111");
        router.scriptReturnsFalse(hex"2222");

        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _recoveryCall(L2_ASSET_ROUTER_ADDR, 0, hex"1111"); // recoverAtomicCall -> false
        calls[1] = _recoveryCall(L2_ASSET_ROUTER_ADDR, 0, hex"2222"); // recoverAtomicCall -> false

        (bytes32 recoveryFlowId, bytes32 bundleHash, bytes memory bundleBytes) = _revertableLegFromBundle(
            _recoveryBundle(calls)
        );

        vm.expectEmit(true, true, false, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(recoveryFlowId, bundleHash);
        manager.claimRefund(recoveryFlowId, bundleBytes);

        assertEq(router.recoverAttempts(), 2, "every router-backed call is still attempted");
        assertEq(router.recoverSuccesses(), 0, "nothing actually recovers");
        assertEq(router.baseTokenRecoveries(), 0, "no base-token payout occurred");
        assertEq(
            uint256(manager.legState(recoveryFlowId, bundleHash)),
            uint256(LegState.Reverted),
            "the leg is terminally Reverted even though nothing was recoverable"
        );

        // Terminal: the no-op refund cannot be claimed again.
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, recoveryFlowId, bundleHash, LegState.Reverted)
        );
        manager.claimRefund(recoveryFlowId, bundleBytes);
    }

    /// @notice A later call reverting during recovery aborts and rolls back the whole claim. Both calls
    /// are reached before the abort; after the failing script is cleared, both are retried and the claim
    /// completes, proving the leg remained `Revertable` and no partial recovery survived.
    function test_claimRefund_multiCall_laterRevertAbortsClaim() public {
        MockRecoveryRouter router = _deployMockRecoveryRouter();
        router.scriptReverts(hex"baad");

        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _recoveryCall(L2_ASSET_ROUTER_ADDR, 0, hex"600d"); // would recover successfully...
        calls[1] = _recoveryCall(L2_ASSET_ROUTER_ADDR, 0, hex"baad"); // ...but this one reverts

        (bytes32 recoveryFlowId, bytes32 bundleHash, bytes memory bundleBytes) = _revertableLegFromBundle(
            _recoveryBundle(calls)
        );

        // Both recovery calls must be reached once in the failed claim and once in the successful retry.
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector, RECOVERY_DEST_CHAIN_ID, hex"600d"),
            2
        );
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector, RECOVERY_DEST_CHAIN_ID, hex"baad"),
            2
        );
        vm.expectRevert("recovery boom");
        manager.claimRefund(recoveryFlowId, bundleBytes);

        assertEq(router.recoverAttempts(), 0, "reverted recovery attempts must roll back");
        assertEq(router.recoverSuccesses(), 0, "the earlier successful recovery must roll back");
        assertEq(
            uint256(manager.legState(recoveryFlowId, bundleHash)),
            uint256(LegState.Revertable),
            "failed claim must leave the refund retryable"
        );

        router.scriptSucceeds(hex"baad");
        vm.expectEmit(true, true, false, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(recoveryFlowId, bundleHash);
        manager.claimRefund(recoveryFlowId, bundleBytes);

        assertEq(router.recoverAttempts(), 2, "retry must process both router-backed calls");
        assertEq(router.recoverSuccesses(), 2, "both recoveries must succeed on retry");
        assertEq(
            uint256(manager.legState(recoveryFlowId, bundleHash)),
            uint256(LegState.Reverted),
            "successful retry must finish the refund"
        );
    }
}
