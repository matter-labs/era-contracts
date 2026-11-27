// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";
import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";
import {MockRecoveryRouter} from "./AtomicFlowManagerRecover.t.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {AtomicFlow, AtomicFlowPreimage, ImtProof, LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerAbsenceChainNotInLeg,
    ManagerFlowIdMismatch,
    ManagerLegNotRevertable,
    ManagerLegChainNotAllowed,
    ProofImtRootInclusionFailed
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_CENTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @dev Writes the `Committed` state a pre-upgrade `append` of a source-only flow left behind: `append` no
/// longer takes one, so no production path can create it any more.
contract AtomicFlowManagerSourceOnlyLegHarness is AtomicFlowManager {
    function commitSourceOnlyLeg(bytes32 _flowId, bytes32 _bundleHash) external {
        _state[_flowId][_bundleHash] = LegState.Committed;
    }
}

/// @notice Covers the refund path's guards in `AtomicFlowManager` — `authorizeRefund`'s proof and
/// chain binding checks (the anti-double-mint, see {protocol-docs/atomicity/proofs.md#timeout})
/// and `claimRefund`'s leg state machine.
/// @dev Manager + commitment tree run at their canonical predeploys; the committed leg goes through
/// the real `append` (pranked canonical InteropCenter). The MISSING leg comes from a remote chain
/// (`MISSING_LEG_CHAIN`) that never takes a step, so the absence of its participation is proven end-to-end
/// through real aggregation + import + {L2MessageVerification} (see {AtomicInteropProofBuilder}); the
/// intrinsically-local case (this chain's own participation is missing) forward-computes its proof instead,
/// and the authentication-failure case withholds the root import.
/// Real fund recovery is covered by `L2AtomicInteropSendRefundTestAbstract` and
/// `AtomicRecoveryForgery.t.sol`.
contract AtomicFlowManagerRefundTest is AtomicInteropProofBuilder {
    uint256 internal constant REMOTE_BATCH_NUMBER = 7;
    uint256 internal constant SL_BLOCK = 300;
    /// @dev The missing leg's remote source chain, also the committed leg's destination — aggregatable in the
    /// settlement-layer MessageRoot (unlike the local chain), so the absence of its participation gets a real,
    /// unmocked authentication.
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

        // A swap: the committed leg goes from this chain to `MISSING_LEG_CHAIN`, which never sends the leg back.
        // The refund names the missing leg, whose source `MISSING_LEG_CHAIN` never participates.
        AtomicFlowPreimage memory swap;
        (swap, , missingLegIndex) = AtomicFlowFixtures.swapPreimage({
            _legA: committedLeg,
            _chainA: block.chainid,
            _legB: missingLeg,
            _chainB: MISSING_LEG_CHAIN,
            _deadline: DEADLINE,
            _settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID
        });
        preimage = swap;
        flowId = AtomicFlowFixtures.flowId(preimage);

        // The remote chains must pass the receive filter of `append` and the refund (a Bridgehub lookup,
        // orthogonal to the atomic proof machinery).
        _setLegChainAllowed(MISSING_LEG_CHAIN, true);
        _setLegChainAllowed(RECOVERY_DEST_CHAIN_ID, true);

        // Commit the real leg through the production send-side path.
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(committedLeg, MISSING_LEG_CHAIN, 0, preimage);
    }

    /// @dev A minimal well-formed bundle for the committed leg. Its call content is irrelevant here:
    /// every claim in this file is rejected by the leg state machine before recovery is attempted
    /// (the recovery mechanics have their own suites, see the contract header).
    function _minimalBundle() internal view returns (InteropBundle memory bundle) {
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: MISSING_LEG_CHAIN,
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256("refund state machine salt"),
            calls: new InteropCall[](0),
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
        });
    }

    /// @dev A genuine end-to-end absence proof for `MISSING_LEG_CHAIN`'s participation (begin branch).
    /// NOT `view`: real aggregation + import mutate settlement-layer state.
    function _validAbsence() internal returns (ImtProof memory) {
        return
            _realTimeoutBeginProof(
                MISSING_LEG_CHAIN,
                AtomicFlowFixtures.participationValue(flowId, MISSING_LEG_CHAIN),
                uint256(DEADLINE) + 1
            );
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
        // A fresh three-leg flow (independent of the setUp fixture): two locally committed legs to
        // `MISSING_LEG_CHAIN` and a never-sent leg back at slot 1, whose chain's missing participation is
        // authenticated by real aggregation.
        bytes32[] memory legs = new bytes32[](3);
        legs[0] = bytes32(uint256(1));
        legs[1] = bytes32(uint256(2));
        legs[2] = bytes32(uint256(3));
        uint256 multiMissingIndex = 1;
        uint256[] memory sources = new uint256[](3);
        (sources[0], sources[1], sources[2]) = (block.chainid, MISSING_LEG_CHAIN, block.chainid);
        uint256[] memory destinations = new uint256[](3);
        (destinations[0], destinations[1], destinations[2]) = (MISSING_LEG_CHAIN, block.chainid, MISSING_LEG_CHAIN);
        AtomicFlowPreimage memory multiPreimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            sources,
            destinations,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        bytes32 multiFlowId = AtomicFlowFixtures.flowId(multiPreimage);

        // Commit BOTH non-missing legs through the production send-side path.
        for (uint256 i = 0; i < 3; ++i) {
            if (i == multiMissingIndex) {
                continue;
            }
            vm.prank(L2_INTEROP_CENTER_ADDR);
            manager.append(multiPreimage.legBundleHashes[i], MISSING_LEG_CHAIN, 0, multiPreimage);
        }

        ImtProof memory absence = _realTimeoutBeginProof(
            MISSING_LEG_CHAIN,
            AtomicFlowFixtures.participationValue(multiFlowId, MISSING_LEG_CHAIN),
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
    /// post-deadline snapshot proves that this chain's own participation was absent: it committed the late
    /// leg but never accepted the peer leg. This pins the case where `_missingLegIndex` is the committed
    /// leg itself, with the absence proven on its source.
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
            destinationChainId: RECOVERY_DEST_CHAIN_ID,
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256("late leg salt"),
            calls: calls,
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
        });
        bytes memory lateBundleBytes = abi.encode(lateBundle);
        bytes32 lateLeg = InteropDataEncoding.encodeInteropBundleHash(lateBundleBytes);
        bytes32 peerLeg = keccak256("late-flow peer leg");

        // A swap with `RECOVERY_DEST_CHAIN_ID`: this chain commits the late leg but never accepts the peer
        // leg, so its own participation (proven absent as the late leg's source) is never inserted.
        (AtomicFlowPreimage memory latePreimage, uint256 lateIdx, ) = AtomicFlowFixtures.swapPreimage({
            _legA: lateLeg,
            _chainA: block.chainid,
            _legB: peerLeg,
            _chainB: RECOVERY_DEST_CHAIN_ID,
            _deadline: DEADLINE,
            _settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID
        });
        bytes32 lateFlowId = AtomicFlowFixtures.flowId(latePreimage);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(lateLeg, RECOVERY_DEST_CHAIN_ID, 0, latePreimage);
        assertEq(
            uint256(manager.legState(lateFlowId, lateLeg)),
            uint256(LegState.Committed),
            "the late leg is locally Committed before the refund"
        );

        // The receive filter accepts this chain's own participation without a whitelist entry: none is set for
        // it here. Intrinsically LOCAL: the proven-absent participation is this chain's, which the
        // settlement-layer MessageRoot cannot aggregate as remote — so this case forward-computes the proof
        // and imports its root directly.
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: block.chainid,
            _batchNumber: REMOTE_BATCH_NUMBER,
            _absentValue: AtomicFlowFixtures.participationValue(lateFlowId, block.chainid),
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 1, aggregatedRoot);

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(lateFlowId, lateLeg);
        manager.authorizeRefund(AtomicFlow({flowId: lateFlowId, preimage: latePreimage}), lateIdx, absence);

        // The load-bearing assertion: the leg at _missingLegIndex itself became Revertable.
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

    /// @notice The double-mint guard: the absence proof must be on a chain the indexed leg DECLARES. A proof
    /// against any other chain's tree is rejected before verification — a participation value exists only in
    /// its own chain's tree and is trivially absent elsewhere.
    function test_RevertWhen_AbsenceChainNotInLeg() public {
        ImtProof memory absence = _validAbsence();
        uint256 unrelatedChainId = 999;
        absence.sourceChainId = unrelatedChainId;

        vm.expectRevert(
            abi.encodeWithSelector(ManagerAbsenceChainNotInLeg.selector, flowId, missingLegIndex, unrelatedChainId)
        );
        manager.authorizeRefund(_flow(), missingLegIndex, absence);
    }

    /// @notice Same guard for a source-only flow, whose legs declare only their source: the missing leg's
    /// commit value is proven absent there, so a proof on any other chain (this one, its destination) is
    /// rejected.
    function test_RevertWhen_SourceOnlyAbsenceNotOnSource() public {
        (uint256 committedIdx, uint256 missingIdx) = committedLeg < missingLeg ? (0, 1) : (1, 0);
        bytes32[] memory legs = new bytes32[](2);
        uint256[] memory chains = new uint256[](2);
        (legs[committedIdx], legs[missingIdx]) = (committedLeg, missingLeg);
        (chains[committedIdx], chains[missingIdx]) = (block.chainid, MISSING_LEG_CHAIN);
        AtomicFlowPreimage memory sourceOnly = AtomicFlowFixtures.sourceOnlyPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        bytes32 sourceOnlyFlowId = AtomicFlowFixtures.flowId(sourceOnly);
        ImtProof memory absence = _validAbsence();
        absence.sourceChainId = block.chainid;

        vm.expectRevert(
            abi.encodeWithSelector(ManagerAbsenceChainNotInLeg.selector, sourceOnlyFlowId, missingIdx, block.chainid)
        );
        manager.authorizeRefund(AtomicFlow({flowId: sourceOnlyFlowId, preimage: sourceOnly}), missingIdx, absence);
    }

    /// @notice The receive filter: this chain refunds only on an absence proven on a chain it accepts
    /// ({protocol-docs/interop-gating.md#receive-filter}). A genuine absence proof from a chain the chain
    /// doesn't allow leaves the committed leg `Committed`.
    function test_RevertWhen_AbsenceChainNotAllowed() public {
        ImtProof memory absence = _validAbsence();
        _setLegChainAllowed(MISSING_LEG_CHAIN, false);

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, MISSING_LEG_CHAIN));
        manager.authorizeRefund(_flow(), missingLegIndex, absence);
        assertEq(
            uint256(manager.legState(flowId, committedLeg)),
            uint256(LegState.Committed),
            "the committed leg must stay Committed"
        );
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
        // Well-formed, but its settlement root is never imported, so the real verifier rejects it.
        (ImtProof memory absence, ) = _nonInclusionProof({
            _sourceChainId: MISSING_LEG_CHAIN,
            _batchNumber: REMOTE_BATCH_NUMBER,
            _absentValue: AtomicFlowFixtures.participationValue(flowId, MISSING_LEG_CHAIN),
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });

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

    /// @notice A source-only flow sent before accepted flows were introduced stays refundable: its timeout
    /// proof is for the missing leg's commit value, and the leg this chain committed flips to `Revertable`.
    /// @dev `append` no longer takes a source-only flow, so the harness writes the state its pre-upgrade
    /// `append` left behind.
    function test_authorizeRefund_SourceOnlyFlowSentBeforeUpgrade() public {
        deployCodeTo(
            "AtomicFlowManagerRefund.t.sol:AtomicFlowManagerSourceOnlyLegHarness",
            L2_ATOMIC_FLOW_MANAGER_ADDR
        );
        AtomicFlowManagerSourceOnlyLegHarness harness = AtomicFlowManagerSourceOnlyLegHarness(
            L2_ATOMIC_FLOW_MANAGER_ADDR
        );

        (uint256 committedIdx, uint256 missingIdx) = committedLeg < missingLeg ? (0, 1) : (1, 0);
        bytes32[] memory legs = new bytes32[](2);
        uint256[] memory chains = new uint256[](2);
        (legs[committedIdx], legs[missingIdx]) = (committedLeg, missingLeg);
        (chains[committedIdx], chains[missingIdx]) = (block.chainid, MISSING_LEG_CHAIN);
        AtomicFlowPreimage memory sourceOnly = AtomicFlowFixtures.sourceOnlyPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        bytes32 sourceOnlyFlowId = AtomicFlowFixtures.flowId(sourceOnly);
        harness.commitSourceOnlyLeg(sourceOnlyFlowId, committedLeg);

        ImtProof memory absence = _realTimeoutBeginProof(
            MISSING_LEG_CHAIN,
            AtomicFlowFixtures.commitValue(sourceOnlyFlowId, missingLeg),
            uint256(DEADLINE) + 1
        );
        vm.expectEmit(true, true, true, true, address(harness));
        emit IAtomicFlowManager.FlowRefundAuthorized(sourceOnlyFlowId, committedLeg);
        harness.authorizeRefund(AtomicFlow({flowId: sourceOnlyFlowId, preimage: sourceOnly}), missingIdx, absence);

        assertEq(
            uint256(harness.legState(sourceOnlyFlowId, committedLeg)),
            uint256(LegState.Revertable),
            "the pre-upgrade leg must become Revertable"
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

    // ============ multi-call recovery through the real Revertable path ============

    /// @dev Drives `_bundle`'s leg to `Revertable` through production entry points only: a real
    /// `append`, then a real `authorizeRefund` against an absence proof for the participation of the chain
    /// that never sends the co-leg.
    /// @dev Consumes `MISSING_LEG_CHAIN`'s single post-genesis batch, so a caller must not also call
    /// {_validAbsence}. `append` must precede the post-deadline root import, hence this order.
    function _revertableLegFromBundle(
        InteropBundle memory _bundle
    ) internal returns (bytes32 recoveryFlowId, bytes32 bundleHash, bytes memory bundleBytes) {
        bundleBytes = abi.encode(_bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundleBytes);
        bytes32 coLeg = keccak256("recovery co-leg");

        // `_bundle` goes to `RECOVERY_DEST_CHAIN_ID`; the co-leg would come from `MISSING_LEG_CHAIN`.
        (uint256 localIdx, uint256 coIdx) = bundleHash < coLeg ? (0, 1) : (1, 0);
        bytes32[] memory legs = new bytes32[](2);
        uint256[] memory sources = new uint256[](2);
        uint256[] memory destinations = new uint256[](2);
        (legs[localIdx], legs[coIdx]) = (bundleHash, coLeg);
        (sources[localIdx], destinations[localIdx]) = (block.chainid, RECOVERY_DEST_CHAIN_ID);
        (sources[coIdx], destinations[coIdx]) = (MISSING_LEG_CHAIN, block.chainid);
        AtomicFlowPreimage memory recoveryPreimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            sources,
            destinations,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        recoveryFlowId = AtomicFlowFixtures.flowId(recoveryPreimage);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(bundleHash, RECOVERY_DEST_CHAIN_ID, 0, recoveryPreimage);

        ImtProof memory absence = _realTimeoutBeginProof(
            MISSING_LEG_CHAIN,
            AtomicFlowFixtures.participationValue(recoveryFlowId, MISSING_LEG_CHAIN),
            uint256(DEADLINE) + 1
        );
        manager.authorizeRefund(AtomicFlow({flowId: recoveryFlowId, preimage: recoveryPreimage}), coIdx, absence);
        assertEq(
            uint256(manager.legState(recoveryFlowId, bundleHash)),
            uint256(LegState.Revertable),
            "fixture: the leg must be Revertable through the real authorize path"
        );
    }

    /// @dev Shared with {AtomicFlowManagerRecoverTest}: unlike `vm.mockCall` its counters are real
    /// storage, so they roll back with a reverting `claimRefund` — what the abort test below proves.
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
