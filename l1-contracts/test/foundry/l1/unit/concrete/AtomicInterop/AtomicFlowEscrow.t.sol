// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {AtomicFlowEscrow} from "contracts/atomic-interop/AtomicFlowEscrow.sol";
import {
    SendSpec,
    SpecState,
    ImtInclusionProof,
    ImtNonInclusionProof
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IAtomicFlowEscrow} from "contracts/atomic-interop/IAtomicFlowEscrow.sol";
import {
    EscrowDepositorMismatch,
    EscrowSelfDestination,
    EscrowSendSpecZeroAmount,
    EscrowSpecAlreadyCommitted,
    EscrowSpecNotExecutable
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {ProofDeadlineExceeded, ProofNonInclusionFailed} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicInteropTestUtils, MockAtomicAssetRouter} from "./AtomicInteropTestUtils.sol";

/// @notice End-to-end tests for the L1-free atomic interop flow under the burn/recover + message-proof
/// model. Two chains (A, B) each run a real {L2InteropCommitmentTree} (IMT engine), an
/// {AtomicFlowEscrow}, and a {MockAtomicAssetRouter} that records the escrow's AR calls.
///
/// Proofs are built from REAL tree state: `chainImtRoot = tree.root()`, `leaf/lowLeaf = tree.leafAt`,
/// `imtProof = tree.merklePath`. The cross-chain authentication of the `(root, timestamp)` message —
/// `proveL2MessageInclusionShared` — is mocked to `true` here; that authentication is exercised
/// end-to-end in the separate anvil-interop suite. `rootTimestamp` is the only knob we vary against the
/// deadline (<= deadline for inclusion, > deadline for non-inclusion); the message proof fields are
/// dummies because the verification call is mocked.
///
/// For the canonical 2-leg swap: a depositor (alice) commits the AB leg on chain A (A = source of AB,
/// destination of BA); carol commits BA on chain B (B = source of BA, destination of AB).
contract AtomicFlowEscrowTest is Test {
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint64 internal constant DEADLINE = 2000;

    // Dummy message-proof fields: the verification call is mocked to true, so these are not inspected.
    uint256 internal constant DUMMY_BATCH = 1;
    uint256 internal constant DUMMY_MSG_INDEX = 0;
    uint16 internal constant DUMMY_TX_IN_BATCH = 0;

    address internal ntv = makeAddr("ntv");

    L2InteropCommitmentTree internal treeA;
    L2InteropCommitmentTree internal treeB;
    AtomicFlowEscrow internal escrowA;
    AtomicFlowEscrow internal escrowB;
    MockAtomicAssetRouter internal arA;
    MockAtomicAssetRouter internal arB;
    TestnetERC20Token internal tokenA;
    TestnetERC20Token internal tokenB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public {
        AtomicInteropTestUtils.installSystemMocks();

        (treeA, escrowA, arA) = _deployStack();
        (treeB, escrowB, arB) = _deployStack();

        tokenA = new TestnetERC20Token("TokenA", "TKA", 18);
        tokenB = new TestnetERC20Token("TokenB", "TKB", 18);
        tokenA.mint(alice, 1_000);
        tokenB.mint(carol, 1_000);
    }

    function _deployStack()
        internal
        returns (L2InteropCommitmentTree tree, AtomicFlowEscrow escrow, MockAtomicAssetRouter ar)
    {
        tree = new L2InteropCommitmentTree();
        escrow = new AtomicFlowEscrow();
        ar = new MockAtomicAssetRouter();
        tree.initialize(address(escrow));
        // ntv can be an arbitrary address: the mock AR does not pull through it, and the escrow only
        // `safeIncreaseAllowance`s the (real) origin token to it.
        escrow.initialize(address(tree), address(ar), ntv);
    }

    function _specAB() internal view returns (SendSpec memory) {
        return SendSpec(CHAIN_B, bob, CHAIN_A, address(tokenA), 100, "", alice);
    }

    function _specBA() internal view returns (SendSpec memory) {
        return SendSpec(CHAIN_A, dave, CHAIN_B, address(tokenB), 50, "", carol);
    }

    // ── Happy path ──────────────────────────────────────────────────────────────────────

    function test_happyPath_commitAuthorizeExecute() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // 1. Commit each source leg on its origin chain.
        uint256 aliceBefore = tokenA.balanceOf(alice);
        uint256 carolBefore = tokenB.balanceOf(carol);
        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _commitSend(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, ba);

        bytes32 hAB = AtomicInteropTestUtils.specHashOf(ab);
        bytes32 hBA = AtomicInteropTestUtils.specHashOf(ba);

        // Source legs are Committed (terminal on the happy path), tokens pulled, AR burn routed once.
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Committed, "AB committed on A (source)");
        assertTrue(escrowB.specState(flowId, hBA) == SpecState.Committed, "BA committed on B (source)");
        assertEq(arA.atomicBurnCount(), 1, "source burn routed via AR on A");
        assertEq(arB.atomicBurnCount(), 1, "source burn routed via AR on B");
        assertEq(arA.lastChainId(), CHAIN_B, "AB burn references dest chain B");
        assertEq(arB.lastChainId(), CHAIN_A, "BA burn references dest chain A");
        assertEq(tokenA.balanceOf(alice), aliceBefore - 100, "alice's tokens pulled");
        assertEq(tokenB.balanceOf(carol), carolBefore - 50, "carol's tokens pulled");
        assertEq(tokenA.balanceOf(address(escrowA)), 100, "source A locked in escrow");
        assertEq(tokenB.balanceOf(address(escrowB)), 50, "source B locked in escrow");

        // 2. Authorize the destination legs: on chain X the verifying escrow checks its own source leg
        //    via local state and the remote leg via an inclusion proof (rootTimestamp <= deadline).
        ImtInclusionProof[] memory proofsA = _remoteInclusionProofs(specs, flowId, CHAIN_A, 1500);
        ImtInclusionProof[] memory proofsB = _remoteInclusionProofs(specs, flowId, CHAIN_B, 1500);

        vm.chainId(CHAIN_A);
        // A is the destination of BA -> expect FlowAuthorized(hBA).
        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowEscrow.FlowAuthorized(flowId, hBA);
        escrowA.authorize(flowId, specs, _chainIds(), DEADLINE, proofsA);

        vm.chainId(CHAIN_B);
        // B is the destination of AB -> expect FlowAuthorized(hAB).
        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowEscrow.FlowAuthorized(flowId, hAB);
        escrowB.authorize(flowId, specs, _chainIds(), DEADLINE, proofsB);

        assertTrue(escrowB.specState(flowId, hAB) == SpecState.Executable, "AB executable on B (dest)");
        assertTrue(escrowA.specState(flowId, hBA) == SpecState.Executable, "BA executable on A (dest)");
        // Source legs are untouched by authorize (terminal at Committed).
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Committed, "AB stays Committed on A (source)");
        assertTrue(escrowB.specState(flowId, hBA) == SpecState.Committed, "BA stays Committed on B (source)");

        // 3. Execute the destination legs: mint to recipient via AR finalizeDeposit, referencing origin.
        vm.chainId(CHAIN_B);
        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowEscrow.FlowExecuted(flowId, hAB);
        escrowB.execute(flowId, ab);

        vm.chainId(CHAIN_A);
        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowEscrow.FlowExecuted(flowId, hBA);
        escrowA.execute(flowId, ba);

        assertTrue(escrowB.specState(flowId, hAB) == SpecState.Executed, "AB executed on B");
        assertTrue(escrowA.specState(flowId, hBA) == SpecState.Executed, "BA executed on A");
        assertEq(arB.finalizeDepositCount(), 1, "destination mint routed via AR on B");
        assertEq(arA.finalizeDepositCount(), 1, "destination mint routed via AR on A");
        assertEq(arB.lastChainId(), CHAIN_A, "AB dest mint references origin chain A");
        assertEq(arA.lastChainId(), CHAIN_B, "BA dest mint references origin chain B");

        // There is NO source execute: source legs remain Committed.
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Committed, "no source execute on A");
        assertTrue(escrowB.specState(flowId, hBA) == SpecState.Committed, "no source execute on B");
    }

    function test_authorize_revertsWhenInclusionProofPastDeadline() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _commitSend(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, ba);

        // The remote inclusion proof carries a root snapshot AFTER the deadline.
        uint256 lateTs = 5000;
        ImtInclusionProof[] memory proofsA = _remoteInclusionProofs(specs, flowId, CHAIN_A, lateTs);

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateTs, DEADLINE));
        escrowA.authorize(flowId, specs, _chainIds(), DEADLINE, proofsA);
    }

    function test_execute_revertsWhenNotAuthorized() public {
        SendSpec memory ab = _specAB();
        bytes32 flowId = keccak256("f");
        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);

        bytes32 hAB = AtomicInteropTestUtils.specHashOf(ab);
        // execute on the destination chain B (AB's dest) before authorize -> not Executable (Unset).
        vm.chainId(CHAIN_B);
        vm.expectRevert(abi.encodeWithSelector(EscrowSpecNotExecutable.selector, hAB, SpecState.Unset));
        escrowB.execute(flowId, ab);
    }

    // ── Timeout / refund path ───────────────────────────────────────────────────────────

    function test_refund_whenLegMissingAcrossDeadline() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // A commits AB; B never commits BA -> B's IMT holds only the head leaf (low-nullifier for BA).
        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);

        // Non-inclusion of BA against B's tree, with a post-deadline root snapshot.
        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, ba, 5000);

        bytes32 hAB = AtomicInteropTestUtils.specHashOf(ab);
        vm.chainId(CHAIN_A);
        vm.expectEmit(true, true, false, false);
        emit IAtomicFlowEscrow.FlowRefundAuthorized(flowId, hAB);
        escrowA.authorizeRefund(flowId, specs, _chainIds(), DEADLINE, _missingIdx(specs, CHAIN_B), proof);
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Revertable, "AB revertable on A");

        // Claim the refund -> AR recoverAtomicBurn routed once, state Reverted. (Tokens are not actually
        // moved back by the mock AR, so we assert via recoverCount/state, not balances.)
        vm.expectEmit(true, true, true, false);
        emit IAtomicFlowEscrow.FlowRefunded(flowId, hAB, alice);
        escrowA.claimRefund(flowId, ab);
        assertEq(arA.recoverCount(), 1, "refund recover routed via AR on A");
        assertEq(arA.lastChainId(), CHAIN_B, "recover references original dest chain B");
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Reverted, "AB reverted on A");
    }

    function test_authorizeRefund_revertsIfLegActuallyPresent() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _commitSend(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, ba); // BA IS present on B

        // Build a non-inclusion proof for BA against B's tree using the head as low-nullifier and a
        // post-deadline timestamp. Because BA's value IS present, the low-nullifier cannot bracket it,
        // so verifyNonInclusion fails -> ProofNonInclusionFailed.
        uint256 baValue = AtomicInteropTestUtils.commitValue(flowId, AtomicInteropTestUtils.specHashOf(ba));
        ImtNonInclusionProof memory proof = ImtNonInclusionProof({
            sourceChainId: CHAIN_B,
            batchNumber: DUMMY_BATCH,
            chainImtRoot: treeB.root(),
            rootTimestamp: 5000, // past deadline so the deadline check passes
            messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
            messageIndex: DUMMY_MSG_INDEX,
            messageProof: new bytes32[](0),
            lowLeaf: treeB.leafAt(0), // head leaf: value 0, next 100... does not bracket a present value
            lowLeafIndex: 0,
            imtProof: treeB.merklePath(0)
        });

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofNonInclusionFailed.selector, treeB.root(), baValue));
        escrowA.authorizeRefund(flowId, specs, _chainIds(), DEADLINE, _missingIdx(specs, CHAIN_B), proof);
    }

    // ── commitSend edge cases ───────────────────────────────────────────────────────────

    function test_commitSend_revertsOnWrongDepositor() public {
        SendSpec memory ab = _specAB();
        vm.chainId(CHAIN_A);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EscrowDepositorMismatch.selector, bob, alice));
        escrowA.commitSend(keccak256("f"), ab, 0);
    }

    function test_commitSend_revertsOnSelfDestination() public {
        SendSpec memory bad = SendSpec(CHAIN_A, bob, CHAIN_A, address(tokenA), 100, "", alice);
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscrowSelfDestination.selector, CHAIN_A));
        escrowA.commitSend(keccak256("f"), bad, 0);
    }

    function test_commitSend_revertsOnZeroAmount() public {
        SendSpec memory bad = SendSpec(CHAIN_B, bob, CHAIN_A, address(tokenA), 0, "", alice);
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.expectRevert(EscrowSendSpecZeroAmount.selector);
        escrowA.commitSend(keccak256("f"), bad, 0);
    }

    function test_commitSend_revertsOnDoubleCommit() public {
        SendSpec memory ab = _specAB();
        bytes32 flowId = keccak256("f");
        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        bytes32 specHash = AtomicInteropTestUtils.specHashOf(ab);

        vm.chainId(CHAIN_A);
        vm.prank(alice);
        tokenA.approve(address(escrowA), 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscrowSpecAlreadyCommitted.selector, specHash));
        escrowA.commitSend(flowId, ab, 0);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = CHAIN_A; // CHAIN_A < CHAIN_B
        ids[1] = CHAIN_B;
    }

    function _missingIdx(SendSpec[] memory _specs, uint256 _originChainId) internal pure returns (uint256) {
        return _specs[0].originChainId == _originChainId ? 0 : 1;
    }

    function _sorted(
        SendSpec memory _ab,
        SendSpec memory _ba
    ) internal pure returns (SendSpec[] memory specs, bytes32[] memory specHashes) {
        bytes32 hAB = AtomicInteropTestUtils.specHashOf(_ab);
        bytes32 hBA = AtomicInteropTestUtils.specHashOf(_ba);
        specs = new SendSpec[](2);
        specHashes = new bytes32[](2);
        if (hAB < hBA) {
            (specs[0], specs[1], specHashes[0], specHashes[1]) = (_ab, _ba, hAB, hBA);
        } else {
            (specs[0], specs[1], specHashes[0], specHashes[1]) = (_ba, _ab, hBA, hAB);
        }
    }

    function _commitSend(
        AtomicFlowEscrow _escrow,
        TestnetERC20Token _token,
        IL2InteropCommitmentTree _tree,
        uint256 _chainId,
        address _payer,
        bytes32 _flowId,
        SendSpec memory _spec
    ) internal {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_spec));
        uint256 lowNull = AtomicInteropTestUtils.lowNullifierIndex(_tree, value);
        vm.chainId(_chainId);
        vm.prank(_payer);
        _token.approve(address(_escrow), _spec.amount);
        vm.prank(_payer);
        _escrow.commitSend(_flowId, _spec, lowNull);
    }

    /// @dev Inclusion proofs for the specs whose origin is NOT `_thisChain`, in sorted spec order — the
    /// only specs needing a proof when authorizing on `_thisChain` (local specs are checked via state).
    function _remoteInclusionProofs(
        SendSpec[] memory _specs,
        bytes32 _flowId,
        uint256 _thisChain,
        uint256 _rootTimestamp
    ) internal view returns (ImtInclusionProof[] memory proofs) {
        uint256 cnt;
        for (uint256 i = 0; i < _specs.length; ++i) {
            if (_specs[i].originChainId != _thisChain) ++cnt;
        }
        proofs = new ImtInclusionProof[](cnt);
        uint256 j;
        for (uint256 i = 0; i < _specs.length; ++i) {
            if (_specs[i].originChainId != _thisChain) {
                proofs[j++] = _inclusion(_specs[i], _flowId, _rootTimestamp);
            }
        }
    }

    function _inclusion(
        SendSpec memory _spec,
        bytes32 _flowId,
        uint256 _rootTimestamp
    ) internal view returns (ImtInclusionProof memory) {
        IL2InteropCommitmentTree tree = _spec.originChainId == CHAIN_A ? treeA : treeB;
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_spec));
        uint256 idx = AtomicInteropTestUtils.indexOfValue(tree, value);
        return
            ImtInclusionProof({
                sourceChainId: _spec.originChainId,
                batchNumber: DUMMY_BATCH,
                chainImtRoot: tree.root(),
                rootTimestamp: _rootTimestamp,
                messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
                messageIndex: DUMMY_MSG_INDEX,
                messageProof: new bytes32[](0),
                leaf: tree.leafAt(idx),
                imtLeafIndex: idx,
                imtProof: tree.merklePath(idx)
            });
    }

    function _nonInclusion(
        IL2InteropCommitmentTree _tree,
        uint256 _chainId,
        bytes32 _flowId,
        SendSpec memory _spec,
        uint256 _rootTimestamp
    ) internal view returns (ImtNonInclusionProof memory) {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_spec));
        uint256 lowIdx = AtomicInteropTestUtils.lowNullifierIndex(_tree, value);
        return
            ImtNonInclusionProof({
                sourceChainId: _chainId,
                batchNumber: DUMMY_BATCH,
                chainImtRoot: _tree.root(),
                rootTimestamp: _rootTimestamp,
                messageTxNumberInBatch: DUMMY_TX_IN_BATCH,
                messageIndex: DUMMY_MSG_INDEX,
                messageProof: new bytes32[](0),
                lowLeaf: _tree.leafAt(lowIdx),
                lowLeafIndex: lowIdx,
                imtProof: _tree.merklePath(lowIdx)
            });
    }
}
