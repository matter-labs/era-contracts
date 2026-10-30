// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AtomicFlowFixtures} from "../../unit/concrete/atomic-interop/AtomicFlowFixtures.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {AtomicInteropProofBuilder} from "../../unit/concrete/atomic-interop/AtomicInteropProofBuilder.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {IL2InteropHandler} from "contracts/interop/interop-handler/IL2InteropHandler.sol";
import {ChainFeature} from "contracts/core/chain-registration/IChainRegistrationSender.sol";
import {
    AtomicFinalityProof,
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof,
    LegState,
    ATOMIC_FLOW_EXPIRY_DELAY,
    ATOMIC_FLOW_PREIMAGE_VERSION
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    BundleAlreadyProcessed,
    ExecutingNotAllowed,
    WrongDestinationChainId
} from "contracts/interop/InteropErrors.sol";
import {IMTLeafValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    ManagerLegNotCommitted,
    ManagerLegSourceChainNotAllowed
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

/// @notice The DESTINATION side of an atomic flow through the real execution entry point:
/// `L2InteropHandler.executeAtomicBundle` with a finality proof for every leg. A real
/// `InteropCenter.sendBundle` (asset-router burn + IMT commit) produces the bundle, the VM switches to
/// the destination chain id, and execution runs the atomicity gate
/// (`AtomicFlowManager.requireFlowFinalized`), the bundle's calls (the destination NTV mint), and the
/// replay guard — all real, against the real Bridgehub interop registry. Each leg's settlement proof is
/// forward-computed by {AtomicInteropProofBuilder} and its root imported, so the real
/// {L2MessageVerification} authenticates both legs.
///
/// L1-context wrapper only (the canonical-address `deployCodeTo`/`vm.etch` setup does not compile
/// under zkFoundry); the full flow also runs on a local node in the anvil-interop
/// `13-imt-atomic-swap` spec.
abstract contract L2AtomicInteropExecuteTestAbstract is L2InteropTestUtils, AtomicInteropProofBuilder {
    /// @dev The remote peer leg of every flow here: committed on the (Bridgehub-registered)
    /// destination chain in the happy paths, withheld in the missing-leg path.
    bytes32 internal constant REMOTE_LEG = keccak256("remote peer leg");
    uint256 internal constant LOCAL_BATCH_NUMBER = 3;
    uint256 internal constant REMOTE_BATCH_NUMBER = 9;

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
        bytes32 bundleHash;
    }
    ExecCtx internal ectx;
    AtomicFlowPreimage internal ectxPreimage;
    /// @dev `abi.encode(InteropBundle)` of the sent bundle, as `executeAtomicBundle` consumes it.
    bytes internal ectxBundleBytes;

    /// @dev Phase 1: real atomic send of a token-transfer leg paired with `REMOTE_LEG` declared on
    /// the destination chain. Records everything the execute phases need.
    /// @param _extraBundleAttribute Optional extra bundle attribute (e.g. `executionAddress`);
    /// zero-length to skip.
    function _sendAtomicLegWithRemotePeer(bytes32 _salt, bytes memory _extraBundleAttribute) internal {
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

        AtomicFlowPreimage memory preimage;
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legSourceChainIds = new uint256[](2);
        (uint256 localIndex, uint256 remoteIndex) = predicted < REMOTE_LEG ? (0, 1) : (1, 0);
        preimage.legBundleHashes[localIndex] = predicted;
        preimage.legBundleHashes[remoteIndex] = REMOTE_LEG;
        preimage.legSourceChainIds[localIndex] = block.chainid;
        preimage.legSourceChainIds[remoteIndex] = destinationChainId;
        ectxPreimage = preimage;
        ectx.flowId = AtomicFlowFixtures.flowId(preimage);

        // The real send carries the atomic metadata out-of-band plus the same bundle attributes.
        bytes[] memory attrs = new bytes[](predictionAttrs.length + 1);
        for (uint256 i = 0; i < predictionAttrs.length; ++i) {
            attrs[i] = predictionAttrs[i];
        }
        attrs[predictionAttrs.length] = abi.encodeCall(IERC7786Attributes.atomicBundle, (preimage, 0));

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

    /// @dev Phase 2: commit the remote peer leg in its (oracle) source tree and assemble the per-leg
    /// finality proofs, positionally aligned with the preimage. Both batches settled in time.
    function _commitRemoteLegAndBuildFinality() internal returns (AtomicFinalityProof memory finality) {
        uint256 remoteIndex = _insertCommit(AtomicFlowFixtures.commitValue(ectx.flowId, REMOTE_LEG));
        finality = _buildFinality(_remoteLegProof(remoteIndex));
    }

    /// @dev Assembles the finality proof from the canonical-tree local proof and `_remoteProof`.
    function _buildFinality(ImtProof memory _remoteProof) internal returns (AtomicFinalityProof memory finality) {
        finality.flow = AtomicFlow({flowId: ectx.flowId, preimage: ectxPreimage});
        finality.proofs = new ImtProof[](2);
        (uint256 localIndex, uint256 remoteIndex) = ectxPreimage.legBundleHashes[0] == ectx.bundleHash
            ? (0, 1)
            : (1, 0);
        finality.proofs[localIndex] = _canonicalTreeInclusionProof(block.chainid, LOCAL_BATCH_NUMBER, 1, DEADLINE - 1);
        finality.proofs[remoteIndex] = _remoteProof;
    }

    /// @dev Inclusion proof for a commit value inserted into the CANONICAL commitment tree (the one
    /// the real atomic send populated) — the mirror of the builder's oracle-tree `_inclusionProof`,
    /// used for the local leg whose commitment went through the production path. The real send
    /// inserted the leg's commit value right after the genesis head leaf (index 1). Imports the proof's
    /// root at a fresh SL block.
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

    /// @notice Happy path: with every leg proven committed in time, the bundle executes on the
    /// destination — the transferred tokens are minted to the receiver, the bundle is marked
    /// `FullyExecuted` (each call `Executed`), and `BundleExecuted` is emitted. The source leg's
    /// local state is untouched (it stays `Committed`; only a timeout could revert it).
    function test_executeAtomicBundle_AllLegsProven_ExecutesBundle() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute happy salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

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

    /// @notice ATOMICITY: a flow whose remote leg was never committed cannot execute — the missing
    /// leg's "proof" (the peer tree's genesis head leaf) fails, the bundle stays `Unreceived`, and
    /// nothing is minted.
    function test_executeAtomicBundle_RevertWhen_RemoteLegNotCommitted() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute missing-leg salt"), bytes(""));

        // The remote leg's commit value was never inserted; the best available "membership" data is
        // the oracle tree's genesis head leaf (index 0), whose value (0) is not the leg's commit value.
        ImtProof memory bogusRemoteProof = _remoteLegProof(0);
        AtomicFinalityProof memory finality = _buildFinality(bogusRemoteProof);

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
    /// leg from that source cannot execute there even with every leg proven — the bundle stays
    /// `Unreceived` and nothing is minted.
    function test_executeAtomicBundle_RevertWhen_SourceNotAllowed() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute disallowed-source salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

        uint256 sourceChainId = block.chainid;
        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(_receiver());
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.deregisterChainForInterop(sourceChainId);

        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainNotAllowed.selector, sourceChainId));
        _executeOnDestination(finality);

        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        assertEq(
            uint256(handler.bundleStatus(ectx.bundleHash)),
            uint256(BundleStatus.Unreceived),
            "bundle must stay Unreceived"
        );
        assertEq(IERC20(ectx.l2Token).balanceOf(_receiver()), receiverBalanceBefore, "nothing must be minted");
    }

    /// @notice The bundle executes only on its destination chain: without the chain-id switch the
    /// destination-context validation rejects it.
    function test_executeAtomicBundle_RevertWhen_WrongDestinationChain() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute wrong-chain salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

        // No vm.chainId: we are still on the source chain.
        vm.expectRevert(
            abi.encodeWithSelector(WrongDestinationChainId.selector, ectx.bundleHash, destinationChainId, block.chainid)
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
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute foreign-executor salt"), executorAttribute);
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

        uint256 sourceChainId = block.chainid;
        vm.chainId(destinationChainId);

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

    /// @notice `verifyAtomicBundle` passes the SAME atomicity gate as execution: with every leg proven
    /// committed in time, the bundle is marked `Verified` (exact event), and NOTHING executes — no
    /// call status changes and no mint.
    function test_verifyAtomicBundle_AllLegsProven_MarksVerifiedWithoutExecuting() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic verify happy salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(_receiver());
        vm.chainId(destinationChainId);

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

    /// @notice ATOMICITY on the verify path: a flow whose remote leg was never committed cannot be
    /// verified — otherwise an arbitrary destination-valid bundle could become `Verified` (and later
    /// unbundled) without its flow ever finalizing. The gate reverts, the bundle stays `Unreceived`,
    /// no `BundleVerified` is emitted, and nothing executes.
    function test_verifyAtomicBundle_RevertWhen_RemoteLegNotCommitted() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic verify missing-leg salt"), bytes(""));

        // The remote leg's commit value was never inserted; the best available "membership" data is
        // the oracle tree's genesis head leaf (index 0), whose value (0) is not the leg's commit value.
        ImtProof memory bogusRemoteProof = _remoteLegProof(0);
        AtomicFinalityProof memory finality = _buildFinality(bogusRemoteProof);

        vm.chainId(destinationChainId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                AtomicFlowFixtures.commitValue(ectx.flowId, REMOTE_LEG),
                0
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
        _sendAtomicLegWithRemotePeer(keccak256("atomic verify-twice salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

        vm.chainId(destinationChainId);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).verifyAtomicBundle(ectxBundleBytes, finality);

        AtomicFinalityProof memory emptyFinality;
        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, ectx.bundleHash));
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).verifyAtomicBundle(ectxBundleBytes, emptyFinality);
    }

    /// @dev The remote leg's oracle-tree proof for the leaf at `_leafIndex`, with its root imported at
    /// a fresh SL block.
    function _remoteLegProof(uint256 _leafIndex) internal returns (ImtProof memory proof) {
        uint256 slBlock = _freshSlBlock();
        bytes32 aggregatedRoot;
        (proof, aggregatedRoot) = _inclusionProof({
            _sourceChainId: destinationChainId,
            _batchNumber: REMOTE_BATCH_NUMBER,
            _leafIndex: _leafIndex,
            _slChainId: L1_CHAIN_ID,
            _slBlock: slBlock,
            _l1Timestamp: DEADLINE - 1
        });
        _importInteropRoot(L1_CHAIN_ID, slBlock, DEADLINE - 1, aggregatedRoot);
    }

    /*//////////////////////////////////////////////////////////////
                    Expiry of single-leg flows
    //////////////////////////////////////////////////////////////*/

    /// @dev Phase 1 of an expirable flow ({protocol-docs/atomicity/expiry.md}): enables the feature for this chain,
    /// through the service transaction the L1 `ChainRegistrationSender` sends, then sends a single-leg flow with one
    /// call to `_to`. Returns the leg's finality proof, settled in time.
    function _sendExpirableLeg(address _to) internal returns (AtomicFinalityProof memory finality) {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.setChainFeatureEnabled(ChainFeature.ExpirableTransfers, true);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(_to),
            data: "",
            callAttributes: new bytes[](0)
        });
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (keccak256("expirable leg")));
        bytes[] memory predictionAttrs = new bytes[](1);
        predictionAttrs[0] = attrs[0];
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.expirablePreimage(
            _predictBundleHashWithAttrs(calls, predictionAttrs),
            block.chainid,
            DEADLINE,
            L1_CHAIN_ID
        );
        attrs[1] = abi.encodeCall(IERC7786Attributes.atomicBundle, (preimage, 0));
        ectxPreimage = preimage;
        ectx.flowId = AtomicFlowFixtures.flowId(preimage);

        vm.recordLogs();
        ectx.bundleHash = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            attrs
        );
        (, , InteropBundle memory sentBundle) = abi.decode(
            extractFirstBundleFromLogs(vm.getRecordedLogs()),
            (bytes32, bytes32, InteropBundle)
        );
        ectxBundleBytes = abi.encode(sentBundle);

        finality.flow = AtomicFlow({flowId: ectx.flowId, preimage: preimage});
        finality.proofs = new ImtProof[](1);
        finality.proofs[0] = _canonicalTreeInclusionProof(block.chainid, LOCAL_BATCH_NUMBER, 1, DEADLINE - 1);
    }

    /// @dev Imports an L1 root stamped after the expiry time of the flows sent here.
    function _passExpiryTime() internal {
        uint256 expiryTime = DEADLINE + ATOMIC_FLOW_EXPIRY_DELAY + 1;
        vm.warp(expiryTime);
        _importInteropRoot(L1_CHAIN_ID, _freshSlBlock(), expiryTime, keccak256("root after expiry"));
    }

    /// @notice {protocol-docs/atomicity/expiry.md} end to end: a leg that can't execute (its call targets an EOA)
    /// expires on the destination, and the expiry value the destination inserted proves the refund on the source.
    function test_expirableLeg_unexecutable_expiresThenRefunds() public {
        _setUpAtomicStack();
        AtomicFinalityProof memory finality = _sendExpirableLeg(makeAddr("EOA"));
        uint256 sourceChainId = block.chainid;
        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);

        vm.chainId(destinationChainId);
        // An EOA has no `receiveMessage`, so the call reverts without data.
        vm.expectRevert(bytes(""));
        handler.executeAtomicBundle(ectxBundleBytes, finality);

        _passExpiryTime();
        // The tree holds its head (index 0) and the leg's commit value (index 1), so the expiry value lands at index
        // 2, after whichever of the two is its predecessor.
        bool afterCommit = AtomicFlowFixtures.expiryValue(ectx.flowId, ectx.bundleHash) >
            AtomicFlowFixtures.commitValue(ectx.flowId, ectx.bundleHash);
        uint256 feeUnitsBefore = l2InteropCenter.interopFeeUnits();
        vm.expectEmit(true, true, true, true, L2_ATOMIC_FLOW_MANAGER_ADDR);
        emit IAtomicFlowManager.FlowExpired(ectx.flowId, ectx.bundleHash, 2);
        vm.expectEmit(true, true, true, true, L2_INTEROP_HANDLER_ADDR);
        emit IL2InteropHandler.BundleExpired(ectx.bundleHash);
        handler.expireAtomicBundle(ectxBundleBytes, finality, afterCommit ? 1 : 0);
        // Expiring sends nothing, so it adds no interop fee units ({protocol-docs/interop-fee.md}).
        assertEq(l2InteropCenter.interopFeeUnits(), feeUnitsBefore, "expiry must not count interop fee units");
        assertEq(uint256(handler.bundleStatus(ectx.bundleHash)), uint256(BundleStatus.Expired));
        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, ectx.bundleHash));
        handler.executeAtomicBundle(ectxBundleBytes, finality);

        vm.chainId(sourceChainId);
        ImtProof memory expiry = _canonicalTreeInclusionProof(
            destinationChainId,
            REMOTE_BATCH_NUMBER,
            2,
            block.timestamp
        );
        vm.expectEmit(true, true, true, true, L2_ATOMIC_FLOW_MANAGER_ADDR);
        emit IAtomicFlowManager.FlowExpiryRefundAuthorized(ectx.flowId, ectx.bundleHash);
        manager.authorizeExpiryRefund(finality.flow, ectxBundleBytes, expiry);
        manager.claimRefund(ectx.flowId, ectxBundleBytes);
        assertEq(uint256(manager.legState(ectx.flowId, ectx.bundleHash)), uint256(LegState.Reverted));

        // A refunded leg is no longer `Committed`, so the same expiry can't authorize a second refund.
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotCommitted.selector, ectx.flowId, ectx.bundleHash, LegState.Reverted)
        );
        manager.authorizeExpiryRefund(finality.flow, ectxBundleBytes, expiry);
    }

    /// @notice Expiry becoming possible doesn't stop execution, and an executed leg can't expire.
    function test_expirableLeg_executesUntilExpired() public {
        _setUpAtomicStack();
        AtomicFinalityProof memory finality = _sendExpirableLeg(interopTargetContract);
        L2InteropHandler handler = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);
        vm.chainId(destinationChainId);
        _passExpiryTime();

        handler.executeAtomicBundle(ectxBundleBytes, finality);
        assertEq(uint256(handler.bundleStatus(ectx.bundleHash)), uint256(BundleStatus.FullyExecuted));

        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, ectx.bundleHash));
        handler.expireAtomicBundle(ectxBundleBytes, finality, 0);
    }
}
