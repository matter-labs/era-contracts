// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {L2GlobalInteropRootImporter} from "contracts/atomic-interop/L2GlobalInteropRootImporter.sol";
import {AtomicFlowEscrow} from "contracts/atomic-interop/AtomicFlowEscrow.sol";
import {
    SendSpec,
    SpecState,
    ImtInclusionProof,
    ImtNonInclusionProof
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    EscrowDepositorMismatch,
    EscrowSelfDestination,
    EscrowSendSpecZeroAmount,
    EscrowSpecAlreadyCommitted,
    EscrowSpecNotExecutable
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {ProofDeadlineExceeded, ProofLowNullifierNotAbove} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    AtomicInteropTestUtils,
    FullMerkleWrapper,
    IndexedImtProver,
    MockAtomicAssetRouter,
    MockBridgehub
} from "./AtomicInteropTestUtils.sol";

/// @notice End-to-end tests for the L1-free atomic interop flow. Submitting chain roots to L1 and
/// importing global roots to L2 are permissionless (temporary stubs), so these tests submit/import
/// without privileged senders. `authorize` requires inclusion proofs ONLY for specs that originate
/// on another chain — specs committed on the verifying chain are checked via local state.
contract AtomicFlowEscrowTest is Test {
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint64 internal constant DEADLINE = 2000;

    GlobalInteropIMT internal registry;
    MockBridgehub internal bridgehub;
    IndexedImtProver internal prover;
    address internal ntv = makeAddr("ntv");

    L2InteropCommitmentTree internal treeA;
    L2InteropCommitmentTree internal treeB;
    L2GlobalInteropRootImporter internal importerA;
    L2GlobalInteropRootImporter internal importerB;
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
        bridgehub = new MockBridgehub();
        registry = new GlobalInteropIMT(address(bridgehub));
        prover = new IndexedImtProver();

        (treeA, importerA, escrowA, arA) = _deployStack();
        (treeB, importerB, escrowB, arB) = _deployStack();

        tokenA = new TestnetERC20Token("TokenA", "TKA", 18);
        tokenB = new TestnetERC20Token("TokenB", "TKB", 18);
        tokenA.mint(alice, 1_000);
        tokenB.mint(carol, 1_000);
    }

    function _deployStack()
        internal
        returns (
            L2InteropCommitmentTree tree,
            L2GlobalInteropRootImporter importer,
            AtomicFlowEscrow escrow,
            MockAtomicAssetRouter ar
        )
    {
        tree = new L2InteropCommitmentTree();
        importer = new L2GlobalInteropRootImporter(); // permissionless; no initialize
        escrow = new AtomicFlowEscrow();
        ar = new MockAtomicAssetRouter();
        tree.initialize(address(escrow));
        escrow.initialize(address(tree), address(importer), address(ar), ntv);
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

        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _commitSend(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, ba);
        assertEq(tokenA.balanceOf(address(escrowA)), 100, "source A locked");
        assertEq(tokenB.balanceOf(address(escrowB)), 50, "source B locked");

        _exposeAndImport(100, 1500);

        // authorize only needs proofs for specs that did NOT originate on the verifying chain.
        ImtInclusionProof[] memory proofsA = _remoteProofs(specs, flowId, 100, CHAIN_A);
        ImtInclusionProof[] memory proofsB = _remoteProofs(specs, flowId, 100, CHAIN_B);

        vm.chainId(CHAIN_A);
        escrowA.authorize(flowId, specs, _chainIds(), DEADLINE, proofsA);
        vm.chainId(CHAIN_B);
        escrowB.authorize(flowId, specs, _chainIds(), DEADLINE, proofsB);

        bytes32 hAB = AtomicInteropTestUtils.specHashOf(ab);
        bytes32 hBA = AtomicInteropTestUtils.specHashOf(ba);
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Executable, "AB executable on A (source)");
        assertTrue(escrowB.specState(flowId, hAB) == SpecState.Executable, "AB executable on B (dest)");

        vm.chainId(CHAIN_A);
        escrowA.execute(flowId, ab);
        vm.chainId(CHAIN_B);
        escrowB.execute(flowId, ab);
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Executed);
        assertTrue(escrowB.specState(flowId, hAB) == SpecState.Executed);
        assertEq(arA.indirectCallCount(), 1, "source burn routed via AR on A");
        assertEq(arB.finalizeDepositCount(), 1, "destination mint routed via AR on B");
        assertEq(arB.lastChainId(), CHAIN_A, "dest mint references origin chain");

        vm.chainId(CHAIN_B);
        escrowB.execute(flowId, ba);
        vm.chainId(CHAIN_A);
        escrowA.execute(flowId, ba);
        assertTrue(escrowB.specState(flowId, hBA) == SpecState.Executed);
        assertTrue(escrowA.specState(flowId, hBA) == SpecState.Executed);
        assertEq(arB.indirectCallCount(), 1, "source burn routed via AR on B");
        assertEq(arA.finalizeDepositCount(), 1, "destination mint routed via AR on A");
    }

    function test_authorize_revertsWhenImportedAfterDeadline() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _commitSend(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, ba);
        _exposeAndImport(100, 5000); // after deadline

        ImtInclusionProof[] memory proofsA = _remoteProofs(specs, flowId, 100, CHAIN_A);
        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, 5000, DEADLINE));
        escrowA.authorize(flowId, specs, _chainIds(), DEADLINE, proofsA);
    }

    function test_execute_revertsWhenNotAuthorized() public {
        SendSpec memory ab = _specAB();
        bytes32 flowId = keccak256("f");
        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);

        bytes32 hAB = AtomicInteropTestUtils.specHashOf(ab);
        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(EscrowSpecNotExecutable.selector, hAB, SpecState.Committed));
        escrowA.execute(flowId, ab);
    }

    // ── Timeout / refund path ───────────────────────────────────────────────────────────

    function test_refund_whenLegMissingAcrossDeadline() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // A commits; B never does (its IMT holds only the head leaf -> low-nullifier for any value).
        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _exposeAndImportForRefund();

        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, ba);

        uint256 aliceBefore = tokenA.balanceOf(alice);
        vm.chainId(CHAIN_A);
        escrowA.authorizeRefund(flowId, specs, _chainIds(), DEADLINE, _missingIdx(specs, CHAIN_B), proof);

        bytes32 hAB = AtomicInteropTestUtils.specHashOf(ab);
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Revertable);

        escrowA.claimRefund(flowId, ab);
        assertEq(tokenA.balanceOf(alice), aliceBefore + 100, "alice refunded");
        assertTrue(escrowA.specState(flowId, hAB) == SpecState.Reverted);
    }

    function test_authorizeRefund_revertsIfLegActuallyPresent() public {
        SendSpec memory ab = _specAB();
        SendSpec memory ba = _specBA();
        (SendSpec[] memory specs, bytes32[] memory specHashes) = _sorted(ab, ba);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commitSend(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, ab);
        _commitSend(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, ba); // BA IS present on B
        _exposeAndImportForRefund();

        uint256 baValue = AtomicInteropTestUtils.commitValue(flowId, AtomicInteropTestUtils.specHashOf(ba));
        FullMerkleWrapper mirror = prover.mirror(treeB);
        ImtNonInclusionProof memory proof = ImtNonInclusionProof({
            chainId: CHAIN_B,
            chainImtRoot: treeB.root(),
            lowLeaf: treeB.leafAt(0),
            lowLeafIndex: 0,
            imtProof: mirror.path(0),
            globalLeafIndex: registry.leafIndexOf(CHAIN_B),
            l1BlockNumberBeforeDeadline: 100,
            globalProofG1: registry.merklePathForChain(CHAIN_B),
            l1BlockNumberAfterDeadline: 200,
            globalProofG2: registry.merklePathForChain(CHAIN_B)
        });

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofLowNullifierNotAbove.selector, baValue, baValue));
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
        uint256 lowNull = prover.lowNullifierIndex(_tree, value);
        vm.chainId(_chainId);
        vm.prank(_payer);
        _token.approve(address(_escrow), _spec.amount);
        vm.prank(_payer);
        _escrow.commitSend(_flowId, _spec, lowNull);
    }

    function _exposeAndImport(uint256 _l1Block, uint256 _timestamp) internal {
        bytes32 rootA = treeA.root();
        bytes32 rootB = treeB.root();
        registry.submitChainRoot(CHAIN_A, 1, rootA);
        registry.submitChainRoot(CHAIN_B, 1, rootB);
        bytes32 gRoot = registry.globalRoot();
        importerA.importGlobalRoot(_l1Block, _timestamp, gRoot);
        importerB.importGlobalRoot(_l1Block, _timestamp, gRoot);
    }

    function _exposeAndImportForRefund() internal {
        bytes32 rootA = treeA.root();
        bytes32 rootB = treeB.root();
        registry.submitChainRoot(CHAIN_A, 1, rootA);
        registry.submitChainRoot(CHAIN_B, 1, rootB);
        bytes32 gRoot = registry.globalRoot();
        importerA.importGlobalRoot(100, 1500, gRoot); // before deadline
        importerA.importGlobalRoot(200, 5000, gRoot); // after deadline
    }

    /// @dev Inclusion proofs for the specs whose origin is NOT `_thisChain`, in sorted order — these
    /// are the only specs that need a proof when authorizing on `_thisChain`.
    function _remoteProofs(
        SendSpec[] memory _specs,
        bytes32 _flowId,
        uint256 _l1Block,
        uint256 _thisChain
    ) internal returns (ImtInclusionProof[] memory proofs) {
        uint256 cnt;
        for (uint256 i = 0; i < _specs.length; ++i) {
            if (_specs[i].originChainId != _thisChain) ++cnt;
        }
        proofs = new ImtInclusionProof[](cnt);
        uint256 j;
        for (uint256 i = 0; i < _specs.length; ++i) {
            if (_specs[i].originChainId != _thisChain) {
                proofs[j++] = _inclusion(_specs[i], _flowId, _l1Block);
            }
        }
    }

    function _inclusion(
        SendSpec memory _spec,
        bytes32 _flowId,
        uint256 _l1Block
    ) internal returns (ImtInclusionProof memory) {
        IL2InteropCommitmentTree tree = _spec.originChainId == CHAIN_A ? treeA : treeB;
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_spec));
        uint256 idx = prover.indexOfValue(tree, value);
        FullMerkleWrapper mirror = prover.mirror(tree);
        return
            ImtInclusionProof({
                chainId: _spec.originChainId,
                chainImtRoot: tree.root(),
                leaf: tree.leafAt(idx),
                imtLeafIndex: idx,
                imtProof: mirror.path(idx),
                globalLeafIndex: registry.leafIndexOf(_spec.originChainId),
                globalProof: registry.merklePathForChain(_spec.originChainId),
                l1BlockNumber: _l1Block
            });
    }

    function _nonInclusion(
        IL2InteropCommitmentTree _tree,
        uint256 _chainId,
        bytes32 _flowId,
        SendSpec memory _spec
    ) internal returns (ImtNonInclusionProof memory) {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_spec));
        uint256 lowIdx = prover.lowNullifierIndex(_tree, value);
        FullMerkleWrapper mirror = prover.mirror(_tree);
        return
            ImtNonInclusionProof({
                chainId: _chainId,
                chainImtRoot: _tree.root(),
                lowLeaf: _tree.leafAt(lowIdx),
                lowLeafIndex: lowIdx,
                imtProof: mirror.path(lowIdx),
                globalLeafIndex: registry.leafIndexOf(_chainId),
                l1BlockNumberBeforeDeadline: 100,
                globalProofG1: registry.merklePathForChain(_chainId),
                l1BlockNumberAfterDeadline: 200,
                globalProofG2: registry.merklePathForChain(_chainId)
            });
    }
}
