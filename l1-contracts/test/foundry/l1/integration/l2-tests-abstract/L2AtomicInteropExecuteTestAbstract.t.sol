// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {L2AtomicInteropTestBase} from "./L2AtomicInteropTestBase.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {
    AtomicFinalityProof,
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof,
    LegState
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    BundleAlreadyProcessed,
    ExecutingNotAllowed,
    WrongDestinationChainId
} from "contracts/interop/InteropErrors.sol";
import {IMTLeafValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {BundleStatus, CallStatus, InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/// @notice The DESTINATION side of an atomic flow, exercised through the REAL execution entry point:
/// `L2InteropHandler.executeAtomicBundle` with a finality proof for every leg. The atomic bundle is
/// produced by a real `InteropCenter.sendBundle` (asset-router burn + IMT commit) on the source
/// chain; the test VM then switches its chain id to the destination (`vm.chainId`, the same pattern
/// `L2InteropTestUtils.executeBundle` uses for non-atomic bundles) and executes: the atomicity gate
/// (`AtomicFlowManager.requireFlowFinalized`) verifies every leg's IMT inclusion proof, the bundle's
/// calls run (the destination NTV mint), and the replay guard closes behind it.
///
/// The local leg's inclusion proof is built from the CANONICAL commitment tree the real send
/// populated; the remote peer leg's from the builder's oracle tree, standing in for the peer chain's
/// IMT. The only logic mock is the separately-tested cross-chain leaf verifier inherited from
/// {AtomicInteropProofBuilder}; the destination-context, executor-permission, replay, and atomicity
/// checks under test all run for real.
abstract contract L2AtomicInteropExecuteTestAbstract is L2AtomicInteropTestBase {
    /// @dev The remote peer leg of every flow here: committed on the (Bridgehub-registered)
    /// destination chain in the happy paths, withheld in the missing-leg path.
    bytes32 internal constant REMOTE_LEG = keccak256("remote peer leg");
    /// @dev Settlement-layer block both legs' batches settle at (arbitrary; authentication mocked).
    uint256 internal constant SL_BLOCK = 401;
    uint256 internal constant LOCAL_BATCH_NUMBER = 3;
    uint256 internal constant REMOTE_BATCH_NUMBER = 9;
    uint256 internal constant TRANSFER_AMOUNT = 100;

    /// @dev Cross-phase context (storage rather than locals to stay under the stack limit; each test
    /// overwrites it fully).
    struct ExecCtx {
        address l2Token;
        address receiver;
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
        ectx.receiver = makeAddr("atomic execute receiver");
        InteropCallStarter[] memory calls = _tokenCallStarter(ectx.l2Token, TRANSFER_AMOUNT, ectx.receiver);

        // The prediction dry run must carry the same BUNDLE attributes as the real send (they are
        // part of the bundle, hence of its hash) — everything except the out-of-band `atomicBundle`.
        bytes[] memory predictionAttrs;
        if (_extraBundleAttribute.length != 0) {
            predictionAttrs = new bytes[](2);
            predictionAttrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
            predictionAttrs[1] = _extraBundleAttribute;
        } else {
            predictionAttrs = new bytes[](1);
            predictionAttrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        }
        uint256 snapshotId = vm.snapshotState();
        bytes32 predicted = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            predictionAttrs
        );
        vm.revertToState(snapshotId);
        AtomicFlowPreimage memory preimage;
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
        ectx.flowId = _flowIdOf(preimage);

        bytes[] memory attrs = _atomicAttributes(preimage, _salt);
        if (_extraBundleAttribute.length != 0) {
            bytes[] memory extended = new bytes[](attrs.length + 1);
            for (uint256 i = 0; i < attrs.length; ++i) {
                extended[i] = attrs[i];
            }
            extended[attrs.length] = _extraBundleAttribute;
            attrs = extended;
        }

        vm.recordLogs();
        ectx.bundleHash = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            attrs
        );
        assertEq(ectx.bundleHash, predicted, "the atomic bundle hash must match the non-atomic prediction");

        (, , InteropBundle memory sentBundle) = abi.decode(
            extractFirstBundleFromLogs(vm.getRecordedLogs()),
            (bytes32, bytes32, InteropBundle)
        );
        ectxBundleBytes = abi.encode(sentBundle);
    }

    /// @dev Phase 2: commit the remote peer leg in its (oracle) source tree and assemble the per-leg
    /// finality proofs, positionally aligned with the preimage. Both batches settled in time.
    function _commitRemoteLegAndBuildFinality() internal returns (AtomicFinalityProof memory finality) {
        uint256 remoteIndex = _insertCommit(_commitValue(ectx.flowId, REMOTE_LEG));
        finality = _buildFinality(
            _inclusionProof(destinationChainId, REMOTE_BATCH_NUMBER, remoteIndex, L1_CHAIN_ID, SL_BLOCK, DEADLINE - 1)
        );
    }

    /// @dev Assembles the finality proof from the canonical-tree local proof and `_remoteProof`.
    function _buildFinality(ImtProof memory _remoteProof) internal view returns (AtomicFinalityProof memory finality) {
        // The real send inserted the local leg's commit value right after the genesis head leaf.
        ImtProof memory localProof = _canonicalTreeInclusionProof(
            block.chainid,
            LOCAL_BATCH_NUMBER,
            1,
            SL_BLOCK,
            DEADLINE - 1
        );

        finality.flow = AtomicFlow({flowId: ectx.flowId, preimage: ectxPreimage});
        finality.proofs = new ImtProof[](2);
        (uint256 localIndex, uint256 remoteIndex) = ectxPreimage.legBundleHashes[0] == ectx.bundleHash
            ? (0, 1)
            : (1, 0);
        finality.proofs[localIndex] = localProof;
        finality.proofs[remoteIndex] = _remoteProof;
    }

    /// @dev Phase 3: become the destination chain and execute. The verifier mock (the one mocked
    /// dependency) is armed here.
    function _executeOnDestination(AtomicFinalityProof memory _finality) internal {
        _mockVerifier(true);
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

        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(ectx.receiver);

        vm.expectEmit(true, true, true, true, L2_INTEROP_HANDLER_ADDR);
        emit IInteropHandlerBase.BundleExecuted(ectx.bundleHash);
        _executeOnDestination(finality);

        assertEq(
            IERC20(ectx.l2Token).balanceOf(ectx.receiver),
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
        // The status marking must stop at the bundle's call count — no stray slot past the end.
        assertEq(
            uint256(handler.callStatus(ectx.bundleHash, 1)),
            uint256(CallStatus.Unprocessed),
            "no call status may be written past the bundle's calls"
        );
        assertEq(
            uint256(AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).legState(ectx.flowId, ectx.bundleHash)),
            uint256(LegState.Committed),
            "execution must not touch the source leg state"
        );
    }

    /// @notice Replay protection: an executed atomic bundle cannot be executed again — atomic
    /// bundles have no verify path, so the status flip at execution is the only replay guard.
    function test_executeAtomicBundle_RevertWhen_Replayed() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute replay salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();
        _executeOnDestination(finality);

        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, ectx.bundleHash));
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);
    }

    /// @notice ATOMICITY: a flow whose remote leg was never committed cannot execute — the missing
    /// leg's "proof" (the peer tree's genesis head leaf) fails, the bundle stays `Unreceived`, and
    /// nothing is minted.
    function test_executeAtomicBundle_RevertWhen_RemoteLegNotCommitted() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute missing-leg salt"), bytes(""));

        // The remote leg's commit value was never inserted; the best available "membership" data is
        // the oracle tree's genesis head leaf, whose value (0) is not the leg's commit value.
        ImtProof memory bogusRemoteProof = ImtProof({
            sourceChainId: destinationChainId,
            batchNumber: REMOTE_BATCH_NUMBER,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: false,
            settlementProof: _settlementProof(L1_CHAIN_ID, SL_BLOCK, DEADLINE - 1, new bytes32[](0)),
            leaf: tree.leafAt(0),
            imtLeafIndex: 0,
            imtProof: tree.merklePath(0)
        });
        AtomicFinalityProof memory finality = _buildFinality(bogusRemoteProof);

        uint256 receiverBalanceBefore = IERC20(ectx.l2Token).balanceOf(ectx.receiver);
        vm.expectRevert(
            abi.encodeWithSelector(IMTLeafValueMismatch.selector, _commitValue(ectx.flowId, REMOTE_LEG), 0)
        );
        _executeOnDestination(finality);

        assertEq(
            uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(ectx.bundleHash)),
            uint256(BundleStatus.Unreceived),
            "a failed atomicity gate must leave the bundle Unreceived"
        );
        assertEq(
            IERC20(ectx.l2Token).balanceOf(ectx.receiver),
            receiverBalanceBefore,
            "a failed atomicity gate must not mint"
        );
    }

    /// @notice The finality proof must carry exactly one proof per leg — the handler forwards it to
    /// the manager gate unchanged.
    function test_executeAtomicBundle_RevertWhen_ProofCountMismatch() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute proof-count salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();
        ImtProof[] memory oneProof = new ImtProof[](1);
        oneProof[0] = finality.proofs[0];
        finality.proofs = oneProof;

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, 2, 1));
        _executeOnDestination(finality);
    }

    /// @notice A fully-proven FOREIGN flow does not authorize executing this bundle: the executing
    /// bundle must be a leg of the flow the proofs are for.
    function test_executeAtomicBundle_RevertWhen_BundleNotLegOfFlow() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute foreign-flow salt"), bytes(""));

        // A foreign flow: two constant legs, both committed in the oracle tree with valid proofs.
        AtomicFlowPreimage memory foreignPreimage;
        foreignPreimage.deadline = DEADLINE;
        foreignPreimage.settlementLayerChainId = L1_CHAIN_ID;
        foreignPreimage.legBundleHashes = new bytes32[](2);
        bytes32 legA = keccak256("foreign leg A");
        bytes32 legB = keccak256("foreign leg B");
        (foreignPreimage.legBundleHashes[0], foreignPreimage.legBundleHashes[1]) = legA < legB
            ? (legA, legB)
            : (legB, legA);
        foreignPreimage.legSourceChainIds = new uint256[](2);
        foreignPreimage.legSourceChainIds[0] = destinationChainId;
        foreignPreimage.legSourceChainIds[1] = destinationChainId;
        bytes32 foreignFlowId = _flowIdOf(foreignPreimage);

        AtomicFinalityProof memory finality;
        finality.flow = AtomicFlow({flowId: foreignFlowId, preimage: foreignPreimage});
        finality.proofs = new ImtProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            uint256 leafIndex = _insertCommit(_commitValue(foreignFlowId, foreignPreimage.legBundleHashes[i]));
            finality.proofs[i] = _inclusionProof(
                destinationChainId,
                REMOTE_BATCH_NUMBER,
                leafIndex,
                L1_CHAIN_ID,
                SL_BLOCK,
                DEADLINE - 1
            );
        }

        vm.expectRevert(
            abi.encodeWithSelector(ManagerExecutingBundleNotInFlow.selector, foreignFlowId, ectx.bundleHash)
        );
        _executeOnDestination(finality);
    }

    /// @notice The bundle executes only on its destination chain: without the chain-id switch the
    /// destination-context validation rejects it.
    function test_executeAtomicBundle_RevertWhen_WrongDestinationChain() public {
        _setUpAtomicStack();
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute wrong-chain salt"), bytes(""));
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();
        _mockVerifier(true);

        // No vm.chainId: we are still on the source chain.
        vm.expectRevert(
            abi.encodeWithSelector(WrongDestinationChainId.selector, ectx.bundleHash, destinationChainId, block.chainid)
        );
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);
    }

    /// @notice A bundle sent with the `executionAddress` attribute — here BOUND to the destination
    /// chain — is executable only by that address on that chain: an arbitrary caller is rejected,
    /// the designated executor succeeds.
    function test_executeAtomicBundle_HonorsExecutionAddress() public {
        _setUpAtomicStack();
        address executor = makeAddr("designated executor");
        bytes memory executorAttribute = abi.encodeCall(
            IERC7786Attributes.executionAddress,
            (InteroperableAddress.formatEvmV1(destinationChainId, executor))
        );
        _sendAtomicLegWithRemotePeer(keccak256("atomic execute executor salt"), executorAttribute);
        AtomicFinalityProof memory finality = _commitRemoteLegAndBuildFinality();

        _mockVerifier(true);
        vm.chainId(destinationChainId);

        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutingNotAllowed.selector,
                ectx.bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, stranger),
                InteroperableAddress.formatEvmV1(destinationChainId, executor)
            )
        );
        vm.prank(stranger);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);

        vm.prank(executor);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(ectxBundleBytes, finality);
        assertEq(
            uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(ectx.bundleHash)),
            uint256(BundleStatus.FullyExecuted),
            "the designated executor's execution must complete"
        );
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

        _mockVerifier(true);
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
}
