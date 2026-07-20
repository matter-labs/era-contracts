// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {AtomicInteropProofBuilder} from "../../unit/concrete/atomic-interop/AtomicInteropProofBuilder.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlow, AtomicFlowPreimage, ImtProof, LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ManagerCommittedBundleNotInFlow} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/// @notice Atomic interop exercised through the REAL send entry point: `InteropCenter.sendBundle` with
/// the `atomicBundle` attribute drives a real `L2AssetRouter.initiateIndirectCall` burn and a real
/// `AtomicFlowManager.append` -> `L2InteropCommitmentTree.insert`, and the timeout path recovers the
/// burn through the real `authorizeRefund` -> `claimRefund` -> `L2AssetRouter.recoverAtomicCall` ->
/// NTV re-mint chain. Everything runs on the shared L2-in-L1-context deployment (real InteropCenter,
/// AssetRouter, NTV, Bridgehub registry and bridged token); the only logic mock is the
/// separately-tested cross-chain leaf verifier inherited from {AtomicInteropProofBuilder}
/// (`L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared`), which absence proofs resolve against.
///
/// Covered flows (complementing the send-time edge cases unit-tested in `AtomicFlowManagerAppend.t.sol`):
///   1. A user sends an atomic leg whose preimage pairs it with an INVALID remote leg
///      (`keccak256("invalid")` — a bundle hash the remote chain will never commit). The send itself
///      succeeds (the preimage is well-formed and contains the local bundle), the funds burn, and the
///      user then recovers them via the timeout path: the invalid leg is proven absent from the remote
///      chain's IMT after the deadline, and `claimRefund` re-mints the burned tokens.
///   2. A preimage that does NOT contain the sent bundle reverts the whole `sendBundle` — including
///      the already-performed burn — leaving the sender's balance untouched.
abstract contract L2AtomicInteropSendRefundTestAbstract is L2InteropTestUtils, AtomicInteropProofBuilder {
    /// @dev The remote leg the reviewer's flow prescribes: a bundle hash no chain will ever commit.
    bytes32 internal constant INVALID_REMOTE_LEG = keccak256("invalid");
    /// @dev Settlement-layer block the post-deadline interop root is imported at (arbitrary).
    uint256 internal constant SL_BLOCK = 201;
    /// @dev Claimed source-batch number for the absence proof (arbitrary; authentication is mocked).
    uint256 internal constant REMOTE_BATCH_NUMBER = 1;

    /// @dev Deploys the atomic predeploys at their canonical addresses (the shared L2-in-L1 deployer
    /// does not include them) and the proof fixtures. Called at the start of each test rather than in
    /// `setUp` to stay independent of the deployer's own setUp chain.
    /// @dev These refund tests exercise the REAL append/finalize/refund logic, so the shared deployer's
    /// void mock of `AtomicFlowManager.append`/`requireFlowFinalized` (installed in its `setUp`) is disabled
    /// here via the {_mockAtomicFlowManager} override; the real contracts are deployed below.
    function _mockAtomicFlowManager() internal virtual override {}

    function _setUpAtomicStack() internal {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        deployCodeTo("L2InteropCommitmentTree.sol:L2InteropCommitmentTree", L2_INTEROP_COMMITMENT_TREE_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).initL2(L1_CHAIN_ID);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).initL2();
        // Proof fixtures from the builder: `tree` below acts as the REMOTE chain's IMT oracle (only
        // its genesis head leaf — the invalid leg is never committed there), plus the real
        // L2InteropRootStorage etched at its canonical address for the timeout clock.
        _setUpAtomicFixtures();
    }

    /// @dev The exact single-call token-transfer starter `InteropLibrary.sendToken` sends: an indirect
    /// call through the L2 AssetRouter, which burns `_amount` of `_l2Token` from the sender.
    function _tokenCallStarter(address _l2Token, uint256 _amount) internal returns (InteropCallStarter[] memory calls) {
        bytes memory secondBridgeCalldata = InteropLibrary.buildSecondBridgeCalldata(
            L2_NATIVE_TOKEN_VAULT.assetId(_l2Token),
            _amount,
            makeAddr("atomic recipient"),
            address(0)
        );
        calls = new InteropCallStarter[](1);
        calls[0] = InteropLibrary.buildSecondBridgeCall(secondBridgeCalldata, L2_ASSET_ROUTER_ADDR);
    }

    /// @dev Predicts the bundle hash the atomic send will produce, via the `previewBundleHash` quoter with
    /// the same calls and salt (the atomic metadata is not part of the bundle, so the hash is identical).
    /// This is the foundry equivalent of the off-chain static `previewBundleHash` preview users do — and,
    /// unlike a real send, it does not require the atomic path (a non-atomic L2->L2 send is unsupported).
    function _predictBundleHash(
        InteropCallStarter[] memory _calls,
        bytes32 _salt
    ) internal returns (bytes32 predicted) {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        // `previewBundleHash` runs the real assembly (including the burning indirect call) but ALWAYS
        // reverts with `InteropPreviewHash(bytes32)`, unwinding the burn — read the hash out of the revert.
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = address(l2InteropCenter).call(
            abi.encodeCall(
                l2InteropCenter.previewBundleHash,
                (InteroperableAddress.formatEvmV1(destinationChainId), _calls, attrs)
            )
        );
        require(!ok, "previewBundleHash must revert with InteropPreviewHash (quoter pattern)");
        require(ret.length == 36, "unexpected preview revert reason");
        // ret layout: 4-byte selector followed by the abi-encoded bytes32 hash.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            predicted := mload(add(ret, 0x24))
        }
    }

    /// @dev Two-leg preimage: the local (predicted) leg on this chain + `INVALID_REMOTE_LEG` declared
    /// on the (Bridgehub-registered) destination chain, leg hashes strictly ascending.
    function _preimageWithInvalidRemoteLeg(
        bytes32 _localLeg
    ) internal view returns (AtomicFlowPreimage memory preimage, uint256 missingLegIndex) {
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legSourceChainIds = new uint256[](2);
        (uint256 localIndex, uint256 remoteIndex) = _localLeg < INVALID_REMOTE_LEG ? (0, 1) : (1, 0);
        preimage.legBundleHashes[localIndex] = _localLeg;
        preimage.legBundleHashes[remoteIndex] = INVALID_REMOTE_LEG;
        preimage.legSourceChainIds[localIndex] = block.chainid;
        preimage.legSourceChainIds[remoteIndex] = destinationChainId;
        missingLegIndex = remoteIndex;
    }

    function _flowIdOf(AtomicFlowPreimage memory _preimage) internal pure returns (bytes32) {
        return keccak256(abi.encode(_preimage));
    }

    function _atomicAttributes(
        AtomicFlowPreimage memory _preimage,
        bytes32 _salt
    ) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](2);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        // Low-nullifier index 0: the canonical commitment tree is fresh (genesis head leaf only).
        attrs[1] = abi.encodeCall(IERC7786Attributes.atomicBundle, (_preimage, 0));
    }

    /// @dev Cross-phase context for the send + refund flow (storage rather than locals to stay under
    /// the stack limit; each test overwrites it fully).
    struct FlowCtx {
        address l2Token;
        uint256 balanceBefore;
        bytes32 flowId;
        bytes32 bundleHash;
        uint256 missingLegIndex;
    }
    FlowCtx internal ctx;
    AtomicFlowPreimage internal ctxPreimage;
    /// @dev `abi.encode(InteropBundle)` of the sent bundle, as `claimRefund` consumes it.
    bytes internal ctxBundleBytes;

    uint256 internal constant TRANSFER_AMOUNT = 100;

    /// @notice The reviewer-prescribed flow: an atomic send whose preimage pairs the (real, burned)
    /// local leg with an invalid remote leg that can never be committed. The send commits fine — and
    /// the user recovers the burned tokens through the timeout path once the invalid leg is proven
    /// absent from its declared source chain after the deadline.
    function test_atomicSend_WithInvalidRemoteLeg_IsRefundableAfterTimeout() public {
        _setUpAtomicStack();
        _sendAtomicLegWithInvalidRemotePeer();
        _authorizeRefundForInvalidRemoteLeg();
        _claimRefundAndAssertRecovery();
    }

    /// @dev Phase 1+2: predict the local leg's hash, send the atomic bundle for real (asset-router
    /// burn + IMT commit) and record everything the refund phases need.
    function _sendAtomicLegWithInvalidRemotePeer() internal {
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        ctx.l2Token = initializeTokenByDeposit();
        bytes32 salt = keccak256("atomic invalid-remote-leg salt");
        InteropCallStarter[] memory calls = _tokenCallStarter(ctx.l2Token, TRANSFER_AMOUNT);

        bytes32 predicted = _predictBundleHash(calls, salt);
        (AtomicFlowPreimage memory preimage, uint256 missingLegIndex) = _preimageWithInvalidRemoteLeg(predicted);
        ctxPreimage = preimage;
        ctx.missingLegIndex = missingLegIndex;
        ctx.flowId = _flowIdOf(preimage);
        ctx.balanceBefore = IERC20(ctx.l2Token).balanceOf(address(this));

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowCommitted(ctx.flowId, predicted, DEADLINE, 1);
        ctx.bundleHash = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _atomicAttributes(preimage, salt)
        );

        // The full bundle rides in the InteropBundleSent event; its bytes are what claimRefund takes.
        (, , InteropBundle memory sentBundle) = abi.decode(
            extractFirstBundleFromLogs(vm.getRecordedLogs()),
            (bytes32, bytes32, InteropBundle)
        );
        ctxBundleBytes = abi.encode(sentBundle);

        assertEq(ctx.bundleHash, predicted, "the atomic bundle hash must match the non-atomic prediction");
        assertEq(
            IERC20(ctx.l2Token).balanceOf(address(this)),
            ctx.balanceBefore - TRANSFER_AMOUNT,
            "the deposit must be burned at send"
        );
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Committed),
            "leg must be Committed after the send"
        );
        assertEq(
            L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).leafAt(1).value,
            _commitValue(ctx.flowId, ctx.bundleHash),
            "the leg's commit value must be inserted into the canonical IMT"
        );
    }

    /// @dev Phase 3: the invalid remote leg can never be committed, so after the deadline it is
    /// provably absent from its declared source chain's IMT (the builder's `tree` oracle, still at its
    /// genesis head leaf). Late-batch branch: batch settled after the deadline, anchored on a
    /// post-deadline settlement interop root.
    function _authorizeRefundForInvalidRemoteLeg() internal {
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        _seedSettlementLayerInteropRoot(L1_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 5);
        _mockVerifier(true);
        ImtProof memory absence = _nonInclusionProof(
            destinationChainId,
            REMOTE_BATCH_NUMBER,
            _commitValue(ctx.flowId, INVALID_REMOTE_LEG),
            L1_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(ctx.flowId, ctx.bundleHash);
        manager.authorizeRefund(AtomicFlow({flowId: ctx.flowId, preimage: ctxPreimage}), ctx.missingLegIndex, absence);
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Revertable),
            "committed local leg must become Revertable"
        );
    }

    /// @dev Phase 4: claimRefund reverses the burn through the real recovery path (asset router ->
    /// NTV re-mint) and the depositor ends where they started.
    function _claimRefundAndAssertRecovery() internal {
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(ctx.flowId, ctx.bundleHash);
        manager.claimRefund(ctx.flowId, ctxBundleBytes);
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Reverted),
            "refunded leg must end Reverted"
        );
        assertEq(
            IERC20(ctx.l2Token).balanceOf(address(this)),
            ctx.balanceBefore,
            "the burned deposit must be re-minted to the depositor"
        );
    }

    /// @notice Send-time coupling through the real entry point: a preimage that does not contain the
    /// sent bundle reverts the whole `sendBundle`, unwinding the already-performed burn — the sender's
    /// balance is untouched and no leg state exists afterwards.
    function test_atomicSend_RevertWhen_BundleNotInPreimage_NothingBurned() public {
        _setUpAtomicStack();
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);

        address l2Token = initializeTokenByDeposit();
        uint256 amount = 100;
        bytes32 salt = keccak256("atomic not-in-preimage salt");
        InteropCallStarter[] memory calls = _tokenCallStarter(l2Token, amount);

        bytes32 predicted = _predictBundleHash(calls, salt);
        // A well-formed preimage that simply does not contain the bundle being sent (e.g. a stale
        // prediction): its single leg is the invalid hash, declared on this chain.
        AtomicFlowPreimage memory preimage;
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](1);
        preimage.legBundleHashes[0] = INVALID_REMOTE_LEG;
        preimage.legSourceChainIds = new uint256[](1);
        preimage.legSourceChainIds[0] = block.chainid;

        uint256 balanceBefore = IERC20(l2Token).balanceOf(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(ManagerCommittedBundleNotInFlow.selector, _flowIdOf(preimage), predicted)
        );
        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _atomicAttributes(preimage, salt)
        );

        assertEq(
            IERC20(l2Token).balanceOf(address(this)),
            balanceBefore,
            "the burn must be unwound with the reverted send"
        );
        assertEq(
            uint256(manager.legState(_flowIdOf(preimage), predicted)),
            uint256(LegState.Unset),
            "no leg state may exist after the reverted send"
        );
    }
}
