// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AtomicFlowFixtures} from "../../unit/concrete/atomic-interop/AtomicFlowFixtures.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {AtomicInteropProofBuilder} from "../../unit/concrete/atomic-interop/AtomicInteropProofBuilder.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {
    AtomicFinalityProof,
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof,
    LegState,
    ATOMIC_PARTICIPATION_LEAF_TAG
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {
    BundleAlreadyProcessed,
    ExecutingNotAllowed,
    InvalidInteropCallVersion,
    ShadowAccountNotSupported,
    WrongDestinationChainId
} from "contracts/interop/InteropErrors.sol";
import {IMTLeafValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    ManagerAcceptedLegSourceChainMismatch,
    ManagerLegChainNotAllowed,
    ManagerLegFromChainToItself
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {BundleStatus, CallStatus, InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/// @notice The DESTINATION side of an atomic flow through the real entry points: `acceptAtomicBundle`, then
/// `executeAtomicBundle` or `verifyAtomicBundle` with a finality proof for every commitment the flow needs. A
/// real `InteropCenter.sendBundle` (asset-router burn) produces the bundle, the VM switches to the destination
/// chain id, and execution runs the atomicity gate (`AtomicFlowManager.requireFlowFinalized`), the bundle's
/// calls (the destination NTV mint), and the replay guard — all real, against the real Bridgehub interop
/// registry. Each settlement proof is forward-computed by {AtomicInteropProofBuilder} and its root imported,
/// so the real {L2MessageVerification} authenticates every commitment.
///
/// L1-context wrapper only (the canonical-address `deployCodeTo`/`vm.etch` setup does not compile
/// under zkFoundry); the full flow also runs on a local node in the anvil-interop
/// `13-imt-atomic-swap` spec.
abstract contract L2AtomicInteropExecuteTestAbstract is L2InteropTestUtils, AtomicInteropProofBuilder {
    /// @dev The remote peer leg of the source-only flows here: committed on the destination chain in the
    /// happy path, withheld in the missing-leg path.
    bytes32 internal constant REMOTE_LEG = keccak256("remote peer leg");
    uint256 internal constant LOCAL_BATCH_NUMBER = 3;
    uint256 internal constant REMOTE_BATCH_NUMBER = 9;
    /// @dev A source a forged bundle claims; no harness chain uses this id.
    uint256 internal constant OTHER_SOURCE_CHAIN_ID = 374;
    /// @dev Deadline of the flow the bundle is really sent under, which differs from the flow under test only
    /// in it (see {_sendAcceptedSingleLeg}).
    uint64 internal constant SENT_FLOW_DEADLINE = DEADLINE + 1;

    /// @dev These tests exercise the REAL append/finalize logic, so the shared deployer's void mock of
    /// `AtomicFlowManager.append`/`requireFlowFinalized` (installed in its `setUp`) is disabled here;
    /// the real contracts are deployed by {_setUpAtomicStack}.
    function _mockAtomicFlowManager() internal virtual override {}

    /// @dev Deploys the atomic predeploys at their canonical addresses (the shared L2-in-L1 deployer
    /// does not include them) and the proof fixtures. Called at the start of each test rather than in
    /// `setUp` to stay independent of the deployer's own setUp chain.
    function _setUpAtomicStack() internal {
        _deployAtomicPredeploys(L1_CHAIN_ID, true);
        // Proof fixtures from the builder: `tree` acts as the REMOTE chain's IMT oracle, plus the
        // real L2InteropRootStorage etched at its canonical address.
        _setUpAtomicFixtures();
        // Both chains share this EVM, so its one Bridgehub also holds the destination's whitelist, whose
        // receive filter must accept this (source) chain.
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.allowInteropPeer(block.chainid, baseTokenAssetId);
    }

    /// @dev The destination-side receiver of the transferred tokens (deterministic; recomputed in
    /// asserts).
    function _receiver() internal returns (address) {
        return makeAddr("atomic recipient");
    }

    /// @dev The exact single-call token-transfer starter `InteropLibrary.sendToken` sends: an indirect
    /// call through the L2 AssetRouter, which burns `_amount` of `_l2Token` from the sender and mints
    /// to {_receiver} on the destination.

    /// @dev Predicts the bundle hash of a send with the given full (non-atomic) bundle-attribute set,
    /// via the `previewBundleHash` quoter — it runs the real assembly but ALWAYS reverts with
    /// `InteropPreviewHash(bytes32)`, unwinding any burn; the hash is read out of the revert data. The
    /// prediction must carry the same BUNDLE attributes as the real send (they are part of the bundle,
    /// hence of its hash) — everything except the out-of-band `atomicBundle`.
    function _predictBundleHashWithAttrs(
        InteropCallStarter[] memory _calls,
        bytes[] memory _predictionAttrs
    ) internal returns (bytes32 predicted) {
        // The matching send below is unpranked, so preview as this contract.
        predicted = _decodePreviewHash(
            address(this),
            abi.encodeCall(
                l2InteropCenter.previewBundleHash,
                (InteroperableAddress.formatEvmV1(destinationChainId), _calls, _predictionAttrs)
            )
        );
    }

    /// @dev Cross-phase context (storage rather than locals to stay under the stack limit; each test
    /// overwrites it fully).
    struct ExecCtx {
        address l2Token;
        bytes32 flowId;
        bytes32 sentFlowId;
        bytes32 bundleHash;
    }
    ExecCtx internal ectx;
    AtomicFlowPreimage internal ectxPreimage;
    /// @dev `abi.encode(InteropBundle)` of the sent bundle, as `executeAtomicBundle` consumes it.
    bytes internal ectxBundleBytes;

    /// @dev Phase 1: real send of a token-transfer leg to `destinationChainId`, and the accepted single-leg flow
    /// under test. Source and destination share this EVM and so one manager, which keeps a single state per
    /// leg: the send's `Committed` would block the destination's `Accepted` under the same flow. So the bundle
    /// is sent under a flow that differs only in its deadline, and the source's participation in the flow
    /// under test is proven from the oracle tree, like a peer chain's (see {_acceptedSingleLegFinality}). The
    /// flow preimage is not part of the bundle, so the bundle is the one the flow under test declares.
    /// @param _extraBundleAttribute Optional extra bundle attribute (e.g. `executionAddress`);
    /// zero-length to skip.
    function _sendAcceptedSingleLeg(bytes32 _salt, bytes memory _extraBundleAttribute) internal {
        ectx.l2Token = initializeTokenByDeposit();
        InteropCallStarter[] memory calls = _tokenCallStarter(ectx.l2Token, TRANSFER_AMOUNT, _receiver());

        bytes[] memory predictionAttrs;
        if (_extraBundleAttribute.length != 0) {
            predictionAttrs = new bytes[](2);
            predictionAttrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
            predictionAttrs[1] = _extraBundleAttribute;
        } else {
            predictionAttrs = new bytes[](1);
            predictionAttrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        }
        bytes32 predicted = _predictBundleHashWithAttrs(calls, predictionAttrs);

        bytes32[] memory legs = new bytes32[](1);
        uint256[] memory sources = new uint256[](1);
        uint256[] memory destinations = new uint256[](1);
        (legs[0], sources[0], destinations[0]) = (predicted, block.chainid, destinationChainId);
        ectxPreimage = AtomicFlowFixtures.nLegPreimage(legs, sources, destinations, DEADLINE, L1_CHAIN_ID);
        ectx.flowId = AtomicFlowFixtures.flowId(ectxPreimage);
        AtomicFlowPreimage memory sentPreimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            sources,
            destinations,
            SENT_FLOW_DEADLINE,
            L1_CHAIN_ID
        );
        ectx.sentFlowId = AtomicFlowFixtures.flowId(sentPreimage);

        // The real send carries the atomic metadata out-of-band plus the same bundle attributes.
        bytes[] memory attrs = new bytes[](predictionAttrs.length + 1);
        for (uint256 i = 0; i < predictionAttrs.length; ++i) {
            attrs[i] = predictionAttrs[i];
        }
        attrs[predictionAttrs.length] = abi.encodeCall(IERC7786Attributes.atomicBundle, (sentPreimage, 0));

        vm.recordLogs();
        ectx.bundleHash = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            attrs
        );
        assertEq(ectx.bundleHash, predicted, "the atomic bundle hash must match the preview prediction");

        (, , InteropBundle memory sentBundle) = abi.decode(
            extractFirstBundleFromLogs(vm.getRecordedLogs()),
            (bytes32, bytes32, InteropBundle)
        );
        ectxBundleBytes = abi.encode(sentBundle);
    }

    /// @dev Phase 2: become the destination chain and accept the leg there. Returns the source chain id.
    function _acceptOnDestination() internal returns (uint256 sourceChainId) {
        sourceChainId = block.chainid;
        vm.chainId(destinationChainId);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(ectxBundleBytes, ectxPreimage, 0);
    }

    /// @dev A source-only flow sent before accepted flows were introduced: the leg paired with `REMOTE_LEG`
    /// declared on the destination chain. Sends take only accepted flows now, so the bundle comes from a real
    /// accepted send and the source's commitment of it under this flow goes into the oracle tree, like the
    /// remote leg's.
    function _sourceOnlyFlowWithRemotePeer(bytes32 _salt) internal {
        _sendAcceptedSingleLeg(_salt, bytes(""));
        bytes32[] memory legs = new bytes32[](2);
        uint256[] memory chains = new uint256[](2);
        (uint256 localIndex, uint256 remoteIndex) = ectx.bundleHash < REMOTE_LEG ? (0, 1) : (1, 0);
        (legs[localIndex], chains[localIndex]) = (ectx.bundleHash, block.chainid);
        (legs[remoteIndex], chains[remoteIndex]) = (REMOTE_LEG, destinationChainId);
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.sourceOnlyPreimage(legs, chains, DEADLINE, L1_CHAIN_ID);
        ectxPreimage = preimage;
        ectx.flowId = AtomicFlowFixtures.flowId(preimage);
    }

    /// @dev Per-leg finality for {_sourceOnlyFlowWithRemotePeer}, positionally aligned with the preimage and
    /// built on the source chain: the local leg's commitment and, if `_remoteLegCommitted`, the remote leg's.
    /// Otherwise the oracle tree's genesis head leaf (value 0) stands in for the remote leg's commitment.
    /// Both batches settled in time.
    function _sourceOnlyFinality(bool _remoteLegCommitted) internal returns (AtomicFinalityProof memory finality) {
        finality.flow = AtomicFlow({flowId: ectx.flowId, preimage: ectxPreimage});
        finality.proofs = new ImtProof[](2);
        (uint256 localIndex, uint256 remoteIndex) = ectxPreimage.legBundleHashes[0] == ectx.bundleHash
            ? (0, 1)
            : (1, 0);
        uint256 localLeaf = _insertCommit(AtomicFlowFixtures.commitValue(ectx.flowId, ectx.bundleHash));
        finality.proofs[localIndex] = _oracleTreeProof(block.chainid, LOCAL_BATCH_NUMBER, localLeaf);
        uint256 remoteLeaf = _remoteLegCommitted
            ? _insertCommit(AtomicFlowFixtures.commitValue(ectx.flowId, REMOTE_LEG))
            : 0;
        finality.proofs[remoteIndex] = _oracleTreeProof(destinationChainId, REMOTE_BATCH_NUMBER, remoteLeaf);
    }

    /// @dev Inclusion proof for the leaf at `_leafIndex` of the CANONICAL commitment tree (the one the real
    /// send and acceptance populate) — the mirror of the builder's oracle-tree `_inclusionProof`. Imports the
    /// proof's root at a fresh SL block.
    function _canonicalTreeInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _l1Timestamp
    ) internal returns (ImtProof memory) {
        L2InteropCommitmentTree canonicalTree = L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR);
        uint256 slBlock = _freshSlBlock();
        (bytes32[] memory settlementProof, bytes32 aggregatedRoot) = _settlementProof({
            _sourceChainId: _sourceChainId,
            _batchNumber: _batchNumber,
            _imtRoot: canonicalTree.root(),
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _otherImtRoot: OTHER_IMT_ROOT,
            _slChainId: L1_CHAIN_ID,
            _slBlock: slBlock,
            _l1Timestamp: _l1Timestamp,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importInteropRoot(L1_CHAIN_ID, slBlock, _l1Timestamp, aggregatedRoot);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: canonicalTree.root(),
                // The finality path always authenticates the end root; the branch bool is ignored.
                provesAgainstBeginRoot: false,
                settlementProof: settlementProof,
                leaf: canonicalTree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: canonicalTree.merklePath(_leafIndex)
            });
    }

    /// @dev Phase 3: become the destination chain and execute.
    function _executeOnDestination(AtomicFinalityProof memory _finality) internal {
        vm.chainId(destinationChainId);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, _finality);
    }

    /// @notice A source-only flow sent before accepted flows were introduced still executes once every leg is
    /// proven committed in time: the transferred tokens are minted to the receiver, the bundle is marked
    /// `FullyExecuted` (each call `Executed`), and `BundleExecuted` is emitted.
    function test_executeAtomicBundle_SourceOnlyFlow_AllLegsProven_ExecutesBundle() public {
        _setUpAtomicStack();
        _sourceOnlyFlowWithRemotePeer(keccak256("atomic execute happy salt"));
        AtomicFinalityProof memory finality = _sourceOnlyFinality(true);

        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(_receiver());

        vm.expectEmit(true, true, true, true, L2_INTEROP_HANDLER_ADDR);
        emit IInteropHandlerBase.BundleExecuted(ectx.bundleHash);
        _executeOnDestination(finality);

        assertEq(
            IERC20(ectx.l2Token).balanceOf(_receiver()),
            receiverBalanceBefore + TRANSFER_AMOUNT,
            "the destination mint must credit the receiver"
        );
        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        assertEq(
            uint256(handler.bundleStatus(ectx.bundleHash)),
            uint256(BundleStatus.FullyExecuted),
            "bundle must be FullyExecuted"
        );
        assertEq(
            uint256(handler.callStatus(ectx.bundleHash, 0)),
            uint256(CallStatus.Executed),
            "the bundle's call must be Executed"
        );
    }

    /// @notice ATOMICITY: a source-only flow whose remote leg was never committed cannot execute — the
    /// missing leg's "proof" (the peer tree's genesis head leaf) fails.
    function test_executeAtomicBundle_SourceOnlyFlow_RevertWhen_RemoteLegNotCommitted() public {
        _setUpAtomicStack();
        _sourceOnlyFlowWithRemotePeer(keccak256("atomic execute missing-leg salt"));
        AtomicFinalityProof memory finality = _sourceOnlyFinality(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                AtomicFlowFixtures.commitValue(ectx.flowId, REMOTE_LEG),
                0
            )
        );
        _executeOnDestination(finality);
    }

    /// @notice RECEIVE FILTER: once the destination drops the source from its whitelist, a flow with a
    /// leg from that source cannot execute there even with every chain's participation proven — the bundle
    /// stays `Unreceived` and nothing is minted.
    function test_executeAtomicBundle_RevertWhen_SourceNotAllowed() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("atomic execute disallowed-source salt"), bytes(""));
        uint256 sourceChainId = _acceptOnDestination();
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(
            sourceChainId,
            DESTINATION_PARTICIPATION_LEAF_INDEX
        );

        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(_receiver());
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.deregisterChainForInterop(sourceChainId);

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, sourceChainId));
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);

        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        assertEq(
            uint256(handler.bundleStatus(ectx.bundleHash)),
            uint256(BundleStatus.Unreceived),
            "bundle must stay Unreceived"
        );
        assertEq(IERC20(ectx.l2Token).balanceOf(_receiver()), receiverBalanceBefore, "nothing must be minted");
    }

    /// @notice The bundle executes only on its destination chain: back on the source chain the
    /// destination-context validation rejects it, even with the flow final.
    function test_executeAtomicBundle_RevertWhen_WrongDestinationChain() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("atomic execute wrong-chain salt"), bytes(""));
        uint256 sourceChainId = _acceptOnDestination();
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(
            sourceChainId,
            DESTINATION_PARTICIPATION_LEAF_INDEX
        );

        vm.chainId(sourceChainId);
        vm.expectRevert(
            abi.encodeWithSelector(WrongDestinationChainId.selector, ectx.bundleHash, destinationChainId, sourceChainId)
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);
    }

    /// @notice The executor binding is CHAIN-SPECIFIC: an executor address bound to a foreign chain
    /// (here: the source chain) authorizes nobody on the destination — not even the named address
    /// itself. Only a matching-chain or chain-agnostic (chain id 0) binding grants execution.
    function test_executeAtomicBundle_RevertWhen_ExecutorBoundToOtherChain() public {
        _setUpAtomicStack();
        address executor = makeAddr("designated executor");
        // Bind the executor to the SOURCE chain: on the destination the binding must not match.
        bytes memory executorAttribute = abi.encodeCall(
            IERC7786Attributes.executionAddress,
            (InteroperableAddress.formatEvmV1(block.chainid, executor))
        );
        _sendAcceptedSingleLeg(keccak256("atomic execute foreign-executor salt"), executorAttribute);
        uint256 sourceChainId = _acceptOnDestination();
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(
            sourceChainId,
            DESTINATION_PARTICIPATION_LEAF_INDEX
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutingNotAllowed.selector,
                ectx.bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, executor),
                InteroperableAddress.formatEvmV1(sourceChainId, executor)
            )
        );
        vm.prank(executor);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);
    }

    // verifyAtomicBundle — the same atomicity gate on the verify (no-execution) path

    /// @notice `verifyAtomicBundle` passes the SAME atomicity gate as execution: with every chain's
    /// participation proven in time, the bundle is marked `Verified` (exact event), and NOTHING executes —
    /// no call status changes and no mint.
    function test_verifyAtomicBundle_AllParticipationsProven_MarksVerifiedWithoutExecuting() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("atomic verify happy salt"), bytes(""));
        uint256 sourceChainId = _acceptOnDestination();
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(
            sourceChainId,
            DESTINATION_PARTICIPATION_LEAF_INDEX
        );

        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(_receiver());

        vm.expectEmit(true, true, true, true, L2_INTEROP_HANDLER_ADDR);
        emit IInteropHandlerBase.BundleVerified(ectx.bundleHash);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).verifyAtomicBundle(ectxBundleBytes, finality);

        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        assertEq(
            uint256(handler.bundleStatus(ectx.bundleHash)),
            uint256(BundleStatus.Verified),
            "bundle must be Verified"
        );
        assertEq(
            uint256(handler.callStatus(ectx.bundleHash, 0)),
            uint256(CallStatus.Unprocessed),
            "verification must not execute any call"
        );
        assertEq(IERC20(ectx.l2Token).balanceOf(_receiver()), receiverBalanceBefore, "verification must not mint");
    }

    /// @notice ATOMICITY on the verify path: without the destination's acceptance the flow cannot be
    /// verified — otherwise an arbitrary destination-valid bundle could become `Verified` (and later
    /// unbundled) without its flow ever finalizing. The destination can only point at the one leaf its tree
    /// holds, the source's participation in the flow the bundle was sent under.
    function test_verifyAtomicBundle_RevertWhen_NotAccepted() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("atomic verify missing-leg salt"), bytes(""));
        uint256 sourceChainId = block.chainid;
        vm.chainId(destinationChainId);
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(sourceChainId, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                _participationValue(destinationChainId),
                AtomicFlowFixtures.participationValue(ectx.sentFlowId, sourceChainId)
            )
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).verifyAtomicBundle(ectxBundleBytes, finality);
    }

    /// @notice A bundle cannot be VERIFIED twice: `_validateVerifiable` requires `Unreceived`, so the
    /// second verify is rejected by the status check BEFORE the finality gate re-runs. Proven by
    /// passing an otherwise-invalid (empty) finality proof on the second call and still getting
    /// `BundleAlreadyProcessed` — if the status check did not gate first, the empty proof would fail
    /// the gate with a different error instead.
    function test_verifyAtomicBundle_RevertWhen_VerifiedTwice() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("atomic verify-twice salt"), bytes(""));
        uint256 sourceChainId = _acceptOnDestination();
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(
            sourceChainId,
            DESTINATION_PARTICIPATION_LEAF_INDEX
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).verifyAtomicBundle(ectxBundleBytes, finality);

        AtomicFinalityProof memory emptyFinality;
        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, ectx.bundleHash));
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).verifyAtomicBundle(ectxBundleBytes, emptyFinality);
    }

    // Accepted flows: the destination accepts the leg before execution
    // ({protocol-docs/atomicity/acceptance.md}). Source and destination share this EVM, so the canonical
    // tree holds the source's participation in the flow the bundle was sent under (leaf 1) and, after
    // `acceptAtomicBundle`, the destination's in the flow under test (leaf 2).

    uint256 internal constant DESTINATION_PARTICIPATION_LEAF_INDEX = 2;

    function _participationValue(uint256 _chainId) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_PARTICIPATION_LEAF_TAG, ectx.flowId, _chainId)));
    }

    /// @dev Finality for the accepted single-leg flow: the source's participation (from the oracle tree, see
    /// {_sendAcceptedSingleLeg}) and the destination's (`_acceptLeafIndex` in the canonical tree), both in time.
    function _acceptedSingleLegFinality(
        uint256 _sourceChainId,
        uint256 _acceptLeafIndex
    ) internal returns (AtomicFinalityProof memory finality) {
        finality.flow = AtomicFlow({flowId: ectx.flowId, preimage: ectxPreimage});
        finality.proofs = new ImtProof[](2);
        uint256 sourceLeaf = _insertCommit(_participationValue(_sourceChainId));
        finality.proofs[0] = _oracleTreeProof(_sourceChainId, LOCAL_BATCH_NUMBER, sourceLeaf);
        finality.proofs[1] = _canonicalTreeInclusionProof(
            destinationChainId,
            REMOTE_BATCH_NUMBER,
            _acceptLeafIndex,
            DEADLINE - 1
        );
    }

    /// @notice Happy path: the destination accepts the leg (its participation value in its IMT, bundle still
    /// `Unreceived`), and once both chains' participations are proven in time the bundle executes.
    function test_acceptAtomicBundle_ThenExecute_AcceptedSingleLeg() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accepted single leg salt"), bytes(""));
        uint256 sourceChainId = block.chainid;
        vm.chainId(destinationChainId);

        vm.expectEmit(true, true, true, true, L2_ATOMIC_FLOW_MANAGER_ADDR);
        emit IAtomicFlowManager.FlowAccepted(ectx.flowId, ectx.bundleHash);
        vm.expectEmit(true, true, true, true, L2_ATOMIC_FLOW_MANAGER_ADDR);
        emit IAtomicFlowManager.FlowParticipated(ectx.flowId, DEADLINE, DESTINATION_PARTICIPATION_LEAF_INDEX);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(ectxBundleBytes, ectxPreimage, 0);

        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        assertEq(
            uint256(IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).legState(ectx.flowId, ectx.bundleHash)),
            uint256(LegState.Accepted),
            "acceptance recorded"
        );
        assertEq(
            L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).leafAt(DESTINATION_PARTICIPATION_LEAF_INDEX).value,
            _participationValue(destinationChainId),
            "participation value in the destination's IMT"
        );
        assertEq(uint256(handler.bundleStatus(ectx.bundleHash)), uint256(BundleStatus.Unreceived), "not executed yet");

        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(
            sourceChainId,
            DESTINATION_PARTICIPATION_LEAF_INDEX
        );
        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(_receiver());
        handler.executeAtomicBundle(ectxBundleBytes, finality);

        assertEq(
            IERC20(ectx.l2Token).balanceOf(_receiver()),
            receiverBalanceBefore + TRANSFER_AMOUNT,
            "the destination mint must credit the receiver"
        );
        assertEq(uint256(handler.bundleStatus(ectx.bundleHash)), uint256(BundleStatus.FullyExecuted), "executed");
    }

    /// @notice Without the destination's acceptance an accepted flow cannot execute, even with the source's
    /// participation proven: the destination can only point at the one leaf its tree holds.
    function test_executeAtomicBundle_AcceptedFlow_RevertWhen_NotAccepted() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("unaccepted single leg salt"), bytes(""));
        uint256 sourceChainId = block.chainid;
        vm.chainId(destinationChainId);
        AtomicFinalityProof memory finality = _acceptedSingleLegFinality(sourceChainId, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                _participationValue(destinationChainId),
                AtomicFlowFixtures.participationValue(ectx.sentFlowId, sourceChainId)
            )
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);
    }

    /// @notice Only the bundle's destination can accept it.
    function test_acceptAtomicBundle_RevertWhen_WrongDestinationChain() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accept on source salt"), bytes(""));

        vm.expectRevert(
            abi.encodeWithSelector(WrongDestinationChainId.selector, ectx.bundleHash, destinationChainId, block.chainid)
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(ectxBundleBytes, ectxPreimage, 0);
    }

    /// @notice An executed bundle cannot be accepted (again).
    function test_acceptAtomicBundle_RevertWhen_AlreadyExecuted() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accept after execution salt"), bytes(""));
        uint256 sourceChainId = block.chainid;
        vm.chainId(destinationChainId);
        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        handler.acceptAtomicBundle(ectxBundleBytes, ectxPreimage, 0);
        handler.executeAtomicBundle(
            ectxBundleBytes,
            _acceptedSingleLegFinality(sourceChainId, DESTINATION_PARTICIPATION_LEAF_INDEX)
        );

        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, ectx.bundleHash));
        handler.acceptAtomicBundle(ectxBundleBytes, ectxPreimage, 0);
    }

    /// @notice Acceptance checks each call's header as execution does: the destination must not commit to a
    /// bundle this release could never execute. The forged bundle is a leg of its own flow, so the header is
    /// the only thing wrong with it.
    function test_acceptAtomicBundle_RevertWhen_UnsupportedCallVersion() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accept bad call version salt"), bytes(""));
        InteropBundle memory bundle = abi.decode(ectxBundleBytes, (InteropBundle));
        bundle.calls[0].version = bytes1(0xff);
        (bytes memory forgedBundle, AtomicFlowPreimage memory preimage) = _flowForForgedBundle(bundle);
        vm.chainId(destinationChainId);

        vm.expectRevert(InvalidInteropCallVersion.selector);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(forgedBundle, preimage, 0);
    }

    /// @notice Acceptance rejects a shadow-account call, which this release cannot execute.
    function test_acceptAtomicBundle_RevertWhen_ShadowAccountCall() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accept shadow account salt"), bytes(""));
        InteropBundle memory bundle = abi.decode(ectxBundleBytes, (InteropBundle));
        bundle.calls[0].shadowAccount = true;
        (bytes memory forgedBundle, AtomicFlowPreimage memory preimage) = _flowForForgedBundle(bundle);
        vm.chainId(destinationChainId);

        vm.expectRevert(ShadowAccountNotSupported.selector);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(forgedBundle, preimage, 0);
    }

    /// @notice The handler passes the bundle's own source to the manager: a bundle claiming another source
    /// cannot be accepted as a leg declared from this one, which that source could never commit.
    function test_acceptAtomicBundle_RevertWhen_BundleFromAnotherSource() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accept other source salt"), bytes(""));
        uint256 sourceChainId = block.chainid;
        InteropBundle memory bundle = abi.decode(ectxBundleBytes, (InteropBundle));
        bundle.sourceChainId = OTHER_SOURCE_CHAIN_ID;
        (bytes memory forgedBundle, AtomicFlowPreimage memory preimage) = _flowForForgedBundle(bundle);
        vm.chainId(destinationChainId);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerAcceptedLegSourceChainMismatch.selector,
                AtomicFlowFixtures.flowId(preimage),
                OTHER_SOURCE_CHAIN_ID,
                sourceChainId
            )
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(forgedBundle, preimage, 0);
    }

    /// @notice Regression: acceptance does not prove where a bundle came from, so a forged bundle claiming the
    /// destination as its own source, under a leg declared from the destination to itself, must not be recorded.
    /// Counted as that chain's send, it would insert its participation and let the forged calls execute.
    function test_acceptAtomicBundle_RevertWhen_ForgedBundleFromThisChain() public {
        _setUpAtomicStack();
        _sendAcceptedSingleLeg(keccak256("accept self source salt"), bytes(""));
        InteropBundle memory bundle = abi.decode(ectxBundleBytes, (InteropBundle));
        bundle.sourceChainId = destinationChainId;
        (bytes memory forgedBundle, AtomicFlowPreimage memory preimage) = _flowForForgedBundle(bundle);
        preimage.legChainIds[0] = destinationChainId;
        vm.chainId(destinationChainId);
        uint256 leavesBefore = L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).leafCount();

        vm.expectRevert(abi.encodeWithSelector(ManagerLegFromChainToItself.selector, 0, destinationChainId));
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).acceptAtomicBundle(forgedBundle, preimage, 0);

        assertEq(
            L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).leafCount(),
            leavesBefore,
            "no participation value"
        );
    }

    /// @dev The sent flow with its only leg replaced by `_bundle`'s hash, so the forged bundle is in its flow.
    function _flowForForgedBundle(
        InteropBundle memory _bundle
    ) internal view returns (bytes memory forgedBundle, AtomicFlowPreimage memory preimage) {
        forgedBundle = abi.encode(_bundle);
        preimage = ectxPreimage;
        preimage.legBundleHashes[0] = keccak256(forgedBundle);
    }

    /// @dev Oracle-tree proof for the leaf at `_leafIndex`, attributed to `_sourceChainId`'s batch
    /// `_batchNumber`, with its root imported at a fresh SL block.
    function _oracleTreeProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex
    ) internal returns (ImtProof memory proof) {
        uint256 slBlock = _freshSlBlock();
        bytes32 aggregatedRoot;
        (proof, aggregatedRoot) = _inclusionProof({
            _sourceChainId: _sourceChainId,
            _batchNumber: _batchNumber,
            _leafIndex: _leafIndex,
            _slChainId: L1_CHAIN_ID,
            _slBlock: slBlock,
            _l1Timestamp: DEADLINE - 1
        });
        _importInteropRoot(L1_CHAIN_ID, slBlock, DEADLINE - 1, aggregatedRoot);
    }
}
