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
import {
    ManagerCommittedBundleNotInFlow,
    ManagerLegNotRevertable,
    ManagerLegSourceChainNotRegistered
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteropPreviewHash} from "contracts/interop/InteropErrors.sol";
import {IL2CrossChainSender} from "contracts/bridge/interfaces/IL2CrossChainSender.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_ASSET_ROUTER, L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/// @notice Minimal depositor for direct native-value legs. The timeout refund is pushed back as a raw ETH
/// transfer (`BaseTokenHolder.recoverBaseToken` -> `Address.sendValue`), so the depositor must be able to
/// receive ETH — the foundry test contract itself has no `receive`.
contract AtomicValueDepositor {
    receive() external payable {}
}

/// @notice Malicious recovery collaborator for the reentrancy regression test: when the base-token refund
/// lands in `receive()` — mid `claimRefund`, during `BaseTokenHolder.recoverBaseToken`'s ETH push — it
/// re-enters `claimRefund` for the SAME leg once and records what the nested claim observed. The nested
/// call is a low-level `.call` so its (expected) revert does not disturb the outer refund.
contract ReentrantRefundClaimer {
    bytes32 internal flowId;
    bytes32 internal bundleHash;
    bytes internal bundleBytes;
    bool internal armed;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;
    LegState public legStateSeenDuringRecovery;

    function arm(bytes32 _flowId, bytes32 _bundleHash, bytes calldata _bundleBytes) external {
        flowId = _flowId;
        bundleHash = _bundleHash;
        bundleBytes = _bundleBytes;
        armed = true;
    }

    receive() external payable {
        if (!armed || reentryAttempted) {
            return;
        }
        reentryAttempted = true;
        legStateSeenDuringRecovery = IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).legState(flowId, bundleHash);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = L2_ATOMIC_FLOW_MANAGER_ADDR.call(
            abi.encodeCall(IAtomicFlowManager.claimRefund, (flowId, bundleBytes))
        );
        reentrySucceeded = ok;
        reentryRevertData = ret;
    }
}

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
///   3. A DIRECT native-value leg to a SAME-base destination: the value is escrowed in the real
///      {BaseTokenHolder} at send, and the timeout refund releases the escrow back to the depositor
///      (`claimRefund` -> asset router -> NTV -> `BaseTokenHolder.recoverBaseToken`).
///   4. A DIRECT value leg to a DIFFERENT-base destination: the destination's base token (a bridged ERC20
///      here) is burned from the depositor at send, and the timeout refund re-mints it through the generic
///      failed-transfer branch of `L2NativeTokenVault._disburseFailedTransfer`.
///   5. Reentrancy: a malicious depositor re-entering `claimRefund` from the recovery ETH push is rejected
///      by the CEI leg-state machine (no `nonReentrant` guard exists by design).
abstract contract L2AtomicInteropSendRefundTestAbstract is L2InteropTestUtils, AtomicInteropProofBuilder {
    /// @dev The remote leg the reviewer's flow prescribes: a bundle hash no chain will ever commit.
    bytes32 internal constant INVALID_REMOTE_LEG = keccak256("invalid");
    /// @dev Native base-token value carried by the same-base direct value legs.
    uint256 internal constant NATIVE_VALUE_LEG_AMOUNT = 3 ether;
    /// @dev Value of the different-base direct value leg, denominated in the destination chain's base token
    /// (held here as a bridged ERC20). Small because the harness mints 100000 units of that token.
    uint256 internal constant BRIDGED_VALUE_LEG_AMOUNT = 100;
    /// @dev Destination chain whose base token differs from this chain's. Chain ids 10 (L1), 270 (era),
    /// 271 (default destination), 300 (mint) and 506 (gateway) are taken by the shared harness.
    uint256 internal constant DIFFERENT_BASE_DEST_CHAIN_ID = 373;
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

    /// @dev Real registry instead of the harness's permissive selector-wide mock: this suite
    /// exercises `AtomicFlowManager.append`'s registration gate, so unregistered chains must
    /// actually read as unregistered (`bytes32(0)`). The chains the suite uses are registered
    /// through the production `registerChainForInterop` entry point.
    function _registerInteropChains() internal virtual override {
        // Hoisted: an external call in the argument position would consume the prank.
        bytes32 ownBaseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.registerChainForInterop(block.chainid, ownBaseTokenAssetId);
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.registerChainForInterop(destinationChainId, destinationBaseTokenAssetId);
    }

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
        return _predictBundleHashFor(address(this), destinationChainId, _calls, _salt);
    }

    /// @dev Sender- and destination-parameterized preview: the salt derivation and each direct call's
    /// `from` depend on the previewing sender, so flows sent by a depositor contract must preview AS it.
    function _predictBundleHashFor(
        address _sender,
        uint256 _destinationChainId,
        InteropCallStarter[] memory _calls,
        bytes32 _salt
    ) internal returns (bytes32 predicted) {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        // `previewBundleHash` runs the real assembly (including the burning indirect call) but ALWAYS
        // reverts with `InteropPreviewHash(bytes32)`, unwinding the burn — read the hash out of the revert.
        vm.prank(_sender);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = address(l2InteropCenter).call(
            abi.encodeCall(
                l2InteropCenter.previewBundleHash,
                (InteroperableAddress.formatEvmV1(_destinationChainId), _calls, attrs)
            )
        );
        require(!ok, "previewBundleHash must revert with InteropPreviewHash (quoter pattern)");
        require(
            ret.length == 36 && bytes4(ret) == InteropPreviewHash.selector,
            "preview must revert with InteropPreviewHash"
        );
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

    /// @notice Sequential-replay coverage: after a completed `claimRefund`, a second independent claim for
    /// the same leg reverts `ManagerLegNotRevertable` — the burned funds can be recovered at most once.
    /// @dev This test only exercises the sequential (non-nested) case; the nested (reentrant) case — a
    /// malicious recovery collaborator re-entering `claimRefund` mid-recovery — is driven in
    /// {test_claimRefund_reentrantClaimDuringRecovery_blocked}.
    function test_atomicSend_RevertWhen_ClaimedTwice() public {
        _setUpAtomicStack();
        _sendAtomicLegWithInvalidRemotePeer();
        _authorizeRefundForInvalidRemoteLeg();
        _claimRefundAndAssertRecovery();

        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, ctx.flowId, ctx.bundleHash, LegState.Reverted)
        );
        manager.claimRefund(ctx.flowId, ctxBundleBytes);
    }

    /// @notice Regression guard for the preview-drain finding: `previewBundleHash` runs the SAME stateful
    /// assembly as a real send — including the value-burning `initiateIndirectCall` (a real asset-router
    /// `bridgeBurn`) — but ALWAYS reverts with `InteropPreviewHash`, so that burn must be rolled back.
    /// Unlike the Solidity salt-suite preview test (value-less call) and the anvil eth_call preview (where
    /// rollback is free regardless of logic), this drives a REAL burning indirect leg on the real stack and
    /// asserts the caller's token balance is unchanged afterwards.
    function test_previewBundleHash_rollsBackBurningIndirectLeg() public {
        _setUpAtomicStack();
        address l2Token = initializeTokenByDeposit();
        InteropCallStarter[] memory calls = _tokenCallStarter(l2Token, TRANSFER_AMOUNT);
        uint256 balanceBefore = IERC20(l2Token).balanceOf(address(this));

        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (keccak256("preview burn rollback")));

        // Prove the burn path was actually ENTERED: the preview assembly routes the token leg through
        // the asset router's `initiateIndirectCall` (the burn). Without this, an early revert before
        // the burn would pass the rollback assertion vacuously.
        vm.expectCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(IL2CrossChainSender.initiateIndirectCall.selector));

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = address(l2InteropCenter).call(
            abi.encodeCall(
                l2InteropCenter.previewBundleHash,
                (InteroperableAddress.formatEvmV1(destinationChainId), calls, attrs)
            )
        );
        assertFalse(ok, "previewBundleHash must revert (quoter pattern)");
        // ...and specifically with `InteropPreviewHash`, not some earlier unrelated revert.
        assertEq(ret.length, 36, "unexpected preview revert reason");
        assertEq(bytes4(ret), InteropPreviewHash.selector, "preview must revert with InteropPreviewHash");
        assertEq(
            IERC20(l2Token).balanceOf(address(this)),
            balanceBefore,
            "the burning indirect leg run during preview must be rolled back by the revert"
        );
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

    /*//////////////////////////////////////////////////////////////
                    Direct value legs (reviewer-requested)
    //////////////////////////////////////////////////////////////*/

    /// @dev The shared harness etches a `DummyL2BaseTokenHolder` (accepts burns, but has no
    /// `recoverBaseToken` and never notifies the asset tracker). The value-leg refund flows below end
    /// inside the REAL holder — escrow release plus the tracker reversal hook — so etch the real
    /// {BaseTokenHolder} over it (same pattern as the asset-tracker flow tests in
    /// {L2InteropHandlerTestAbstract}); the harness-seeded escrow balance survives `vm.etch`.
    function _etchRealBaseTokenHolder() internal {
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        // The shared deployer's DiamondInit call-mocker (`getExampleChainCommitment`) overrides
        // `NTV.originChainId(baseTokenAssetId)` to `block.chainid`, which would make the asset tracker
        // treat the base token as NATIVE to this chain and hit the chain-balance accounting. The real NTV
        // storage holds L1_CHAIN_ID (a base token is never native to its own L2, an invariant
        // `handleRecoverBaseTokenBridgingOnL2` asserts) — re-mock it back to the real value so the
        // tracker takes the production non-native branches.
        vm.mockCall(
            address(L2_NATIVE_TOKEN_VAULT),
            abi.encodeCall(INativeTokenVaultBase.originChainId, (baseTokenAssetId)),
            abi.encode(L1_CHAIN_ID)
        );
    }

    /// @dev Same-base variant of {_sendAtomicLegWithInvalidRemotePeer}: sends a DIRECT native-value leg
    /// (no token, no indirect call) from `_depositor`, escrowing `NATIVE_VALUE_LEG_AMOUNT` in the real
    /// BaseTokenHolder, and records everything the refund phases need.
    function _sendDirectValueLegWithInvalidRemotePeer(address _depositor) internal {
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        bytes32 salt = keccak256("atomic direct value leg salt");
        // The destination shares this chain's base token (the harness registers every chain with the same
        // base-token asset id), so the library builds the DIRECT value-carrying starter.
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropLibrary.buildSendDestinationChainBaseTokenCall(
            destinationChainId,
            makeAddr("value recipient"),
            NATIVE_VALUE_LEG_AMOUNT
        );

        bytes32 predicted = _predictBundleHashFor(_depositor, destinationChainId, calls, salt);
        (AtomicFlowPreimage memory preimage, uint256 missingLegIndex) = _preimageWithInvalidRemoteLeg(predicted);
        ctxPreimage = preimage;
        ctx.missingLegIndex = missingLegIndex;
        ctx.flowId = _flowIdOf(preimage);

        vm.deal(_depositor, NATIVE_VALUE_LEG_AMOUNT);
        uint256 holderBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // The escrow leg: the collected value must reach the BaseTokenHolder, and the asset tracker must
        // be notified of the outbound bridging with the original (destination, amount).
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeCall(
                IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2,
                (destinationChainId, NATIVE_VALUE_LEG_AMOUNT)
            )
        );
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowCommitted(ctx.flowId, predicted, DEADLINE, 1);
        vm.prank(_depositor);
        ctx.bundleHash = l2InteropCenter.sendBundle{value: NATIVE_VALUE_LEG_AMOUNT}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _atomicAttributes(preimage, salt)
        );

        (, , InteropBundle memory sentBundle) = abi.decode(
            extractFirstBundleFromLogs(vm.getRecordedLogs()),
            (bytes32, bytes32, InteropBundle)
        );
        ctxBundleBytes = abi.encode(sentBundle);

        assertEq(ctx.bundleHash, predicted, "the atomic bundle hash must match the prediction");
        assertEq(_depositor.balance, 0, "the value must be collected from the depositor at send");
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBefore + NATIVE_VALUE_LEG_AMOUNT,
            "the collected value must be escrowed in the BaseTokenHolder"
        );
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Committed),
            "leg must be Committed after the send"
        );
    }

    /// @notice Real-stack SAME-BASE direct value leg refund: the destination chain shares this chain's
    /// base token, so `sendBundle{value: ...}` escrows the value in the REAL {BaseTokenHolder}, and the
    /// timeout refund releases that escrow back to the depositor through the full `claimRefund` ->
    /// asset router -> NTV -> `BaseTokenHolder.recoverBaseToken` chain — the branch the dispatch-only
    /// unit tests ({AtomicFlowManagerRecover.t.sol}) stop short of.
    function test_atomicSend_directValueLeg_sameBase_timeoutRefundsEscrowedValue() public {
        _setUpAtomicStack();
        _etchRealBaseTokenHolder();
        AtomicValueDepositor depositor = new AtomicValueDepositor();
        _sendDirectValueLegWithInvalidRemotePeer(address(depositor));
        _authorizeRefundForInvalidRemoteLeg();

        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        uint256 holderBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // The recovery hook must reverse the send-time accounting with the original (destination, amount).
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeCall(
                IL2AssetTracker.handleRecoverBaseTokenBridgingOnL2,
                (destinationChainId, NATIVE_VALUE_LEG_AMOUNT)
            )
        );
        vm.expectEmit(true, false, false, true, L2_BASE_TOKEN_HOLDER_ADDR);
        emit IBaseTokenHolder.BaseTokenRecovered(address(depositor), NATIVE_VALUE_LEG_AMOUNT);
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(ctx.flowId, ctx.bundleHash);
        manager.claimRefund(ctx.flowId, ctxBundleBytes);

        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Reverted),
            "refunded leg must end Reverted"
        );
        assertEq(
            address(depositor).balance,
            NATIVE_VALUE_LEG_AMOUNT,
            "the escrowed base-token value must return to the depositor"
        );
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBefore - NATIVE_VALUE_LEG_AMOUNT,
            "the escrow must leave the BaseTokenHolder"
        );
    }

    /// @notice Real-stack DIFFERENT-BASE direct value leg refund: the destination chain's base token is a
    /// bridged ERC20 on this chain, so the send collects the value by burning that token from the
    /// depositor (`bridgehubDepositBaseToken`), and the timeout refund re-mints it through the generic
    /// failed-transfer branch of `L2NativeTokenVault._disburseFailedTransfer` — the other side of the
    /// divergence the dispatch-only unit tests stop short of.
    function test_atomicSend_directValueLeg_differentBase_timeoutRemintsBridgedBaseToken() public {
        _setUpAtomicStack();
        address depositor = makeAddr("differentBaseDepositor");
        _sendDifferentBaseValueLegWithInvalidRemotePeer(depositor);
        _authorizeRefundForInvalidRemoteLeg();

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
            IERC20(ctx.l2Token).balanceOf(depositor),
            BRIDGED_VALUE_LEG_AMOUNT,
            "the burned destination base token must be re-minted to the depositor"
        );
    }

    /// @dev Different-base variant of {_sendAtomicLegWithInvalidRemotePeer}: sends a DIRECT value leg to
    /// `DIFFERENT_BASE_DEST_CHAIN_ID`, whose base token is the harness's bridged L1-origin test token —
    /// burned from `_depositor` at send (`bridgehubDepositBaseToken`) — and records everything the refund
    /// phases need (the token in `ctx.l2Token`).
    function _sendDifferentBaseValueLegWithInvalidRemotePeer(address _depositor) internal {
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        // The destination's base token, held on this chain as the harness's bridged L1-origin test token.
        ctx.l2Token = initializeTokenByDeposit();
        IERC20(ctx.l2Token).transfer(_depositor, BRIDGED_VALUE_LEG_AMOUNT);

        // Register the different-base destination through the REAL registry (see
        // {_registerInteropChains}): the one entry whose base token differs.
        bytes32 differentBaseAssetId = L2_NATIVE_TOKEN_VAULT.assetId(ctx.l2Token);
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.registerChainForInterop(DIFFERENT_BASE_DEST_CHAIN_ID, differentBaseAssetId);

        // A direct value leg built by hand: `InteropLibrary.buildSendDestinationChainBaseTokenCall` routes
        // different-base transfers indirectly (bridging THIS chain's base token as an asset); here we
        // specifically need a DIRECT call carrying destination-side `value`.
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (BRIDGED_VALUE_LEG_AMOUNT));
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("value recipient")),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes32 salt = keccak256("atomic different-base value leg salt");
        bytes32 predicted = _predictBundleHashFor(_depositor, DIFFERENT_BASE_DEST_CHAIN_ID, calls, salt);
        (AtomicFlowPreimage memory preimage, uint256 missingLegIndex) = _preimageWithInvalidRemoteLeg(predicted);
        ctxPreimage = preimage;
        ctx.missingLegIndex = missingLegIndex;
        ctx.flowId = _flowIdOf(preimage);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowCommitted(ctx.flowId, predicted, DEADLINE, 1);
        vm.prank(_depositor);
        // No `msg.value`: for a different-base destination the value is collected in the bridged base token.
        ctx.bundleHash = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(DIFFERENT_BASE_DEST_CHAIN_ID),
            calls,
            _atomicAttributes(preimage, salt)
        );
        (, , InteropBundle memory sentBundle) = abi.decode(
            extractFirstBundleFromLogs(vm.getRecordedLogs()),
            (bytes32, bytes32, InteropBundle)
        );
        ctxBundleBytes = abi.encode(sentBundle);

        assertEq(ctx.bundleHash, predicted, "the atomic bundle hash must match the prediction");
        assertEq(
            IERC20(ctx.l2Token).balanceOf(_depositor),
            0,
            "the destination base token must be burned from the depositor at send"
        );
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Committed),
            "leg must be Committed after the send"
        );
    }

    /// @notice Reentrancy regression: `claimRefund` deliberately has no `nonReentrant` guard — safety
    /// rests on CEI (the leg flips to `Reverted` BEFORE the external recovery calls). A malicious
    /// depositor re-entering `claimRefund` from inside the recovery's ETH push must observe the leg
    /// already `Reverted`, have its nested claim rejected, and receive exactly one payout, while the
    /// outer refund completes normally.
    function test_claimRefund_reentrantClaimDuringRecovery_blocked() public {
        _setUpAtomicStack();
        _etchRealBaseTokenHolder();
        ReentrantRefundClaimer depositor = new ReentrantRefundClaimer();
        _sendDirectValueLegWithInvalidRemotePeer(address(depositor));
        _authorizeRefundForInvalidRemoteLeg();
        depositor.arm(ctx.flowId, ctx.bundleHash, ctxBundleBytes);

        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(ctx.flowId, ctx.bundleHash);
        manager.claimRefund(ctx.flowId, ctxBundleBytes);

        assertTrue(
            depositor.reentryAttempted(),
            "the malicious depositor must have re-entered during the recovery ETH push"
        );
        assertEq(
            uint256(depositor.legStateSeenDuringRecovery()),
            uint256(LegState.Reverted),
            "CEI: the leg must already be Reverted when the external recovery call runs"
        );
        assertFalse(depositor.reentrySucceeded(), "the nested claim must revert");
        assertEq(
            depositor.reentryRevertData(),
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, ctx.flowId, ctx.bundleHash, LegState.Reverted),
            "the nested claim must be rejected by the Revertable state check"
        );
        assertEq(address(depositor).balance, NATIVE_VALUE_LEG_AMOUNT, "exactly one recovery payout may occur");
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Reverted),
            "leg must stay Reverted"
        );
    }

    /// @notice Re-authorization while the leg is still `Revertable` (BEFORE any claim) is inert:
    /// only `Committed` legs transition, so a second authorization with a fresh valid proof emits no
    /// event and leaves the leg `Revertable`. Together with the post-claim case
    /// ({test_authorizeRefund_ResubmittedProofAfterClaimIsInert}), this pins the full "Committed-only"
    /// transition across both non-Committed states.
    function test_authorizeRefund_SecondAuthorizationBeforeClaimIsInert() public {
        _setUpAtomicStack();
        _sendAtomicLegWithInvalidRemotePeer();
        _authorizeRefundForInvalidRemoteLeg(); // leg -> Revertable, first event emitted

        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        ImtProof memory absence = _nonInclusionProof(
            destinationChainId,
            REMOTE_BATCH_NUMBER,
            _commitValue(ctx.flowId, INVALID_REMOTE_LEG),
            L1_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );

        vm.recordLogs();
        manager.authorizeRefund(AtomicFlow({flowId: ctx.flowId, preimage: ctxPreimage}), ctx.missingLegIndex, absence);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IAtomicFlowManager.FlowRefundAuthorized.selector,
                "re-authorizing an already-Revertable leg must not emit FlowRefundAuthorized"
            );
        }
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Revertable),
            "the leg must stay Revertable across a redundant authorization"
        );
    }

    /// @notice A completed refund cannot be REOPENED: resubmitting the same (still-valid) timeout
    /// proof after authorize -> claim is inert — no authorization event, the leg stays terminal
    /// `Reverted` (not flipped back to `Revertable`), a further claim still reverts, and the balance
    /// is unchanged. Without the Committed-only transition this would re-arm the leg for a second
    /// payout of the same burn.
    function test_authorizeRefund_ResubmittedProofAfterClaimIsInert() public {
        _setUpAtomicStack();
        _sendAtomicLegWithInvalidRemotePeer();
        _authorizeRefundForInvalidRemoteLeg();
        _claimRefundAndAssertRecovery();

        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        uint256 balanceAfterRefund = IERC20(ctx.l2Token).balanceOf(address(this));
        // The same absence proof `_authorizeRefundForInvalidRemoteLeg` used: the invalid remote leg
        // is still absent from its source chain's tree, so the proof itself still verifies.
        ImtProof memory absence = _nonInclusionProof(
            destinationChainId,
            REMOTE_BATCH_NUMBER,
            _commitValue(ctx.flowId, INVALID_REMOTE_LEG),
            L1_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );

        vm.recordLogs();
        manager.authorizeRefund(AtomicFlow({flowId: ctx.flowId, preimage: ctxPreimage}), ctx.missingLegIndex, absence);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IAtomicFlowManager.FlowRefundAuthorized.selector,
                "re-authorization after a completed refund must not emit FlowRefundAuthorized"
            );
        }
        assertEq(
            uint256(manager.legState(ctx.flowId, ctx.bundleHash)),
            uint256(LegState.Reverted),
            "the refunded leg must stay terminal Reverted"
        );

        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, ctx.flowId, ctx.bundleHash, LegState.Reverted)
        );
        manager.claimRefund(ctx.flowId, ctxBundleBytes);
        assertEq(
            IERC20(ctx.l2Token).balanceOf(address(this)),
            balanceAfterRefund,
            "a reopened claim attempt must not move funds"
        );
    }

    /// @notice The other end of the claim state machine (complementing
    /// {test_atomicSend_RevertWhen_ClaimedTwice}): a merely `Committed` leg — no timeout authorized —
    /// cannot be claimed. This gate is the only thing standing between a live, finalizable leg and a
    /// unilateral refund.
    function test_claimRefund_RevertWhen_NotAuthorized() public {
        _setUpAtomicStack();
        _sendAtomicLegWithInvalidRemotePeer();

        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, ctx.flowId, ctx.bundleHash, LegState.Committed)
        );
        AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).claimRefund(ctx.flowId, ctxBundleBytes);
    }

    /// @notice The registration gate through the REAL registry: an atomic send whose preimage
    /// declares a co-leg on an unregistered (phantom) chain reverts the whole send — such a leg could
    /// neither be proven committed nor proven absent, stranding every other leg of the flow. Possible
    /// to assert here because this suite registers chains for real (see {_registerInteropChains})
    /// instead of inheriting the harness's permissive registry mock.
    function test_atomicSend_RevertWhen_CoLegChainNotRegistered() public {
        _setUpAtomicStack();
        uint256 phantomChainId = 999_999;

        address l2Token = initializeTokenByDeposit();
        bytes32 salt = keccak256("atomic phantom co-leg salt");
        InteropCallStarter[] memory calls = _tokenCallStarter(l2Token, TRANSFER_AMOUNT);

        bytes32 predicted = _predictBundleHash(calls, salt);
        (AtomicFlowPreimage memory preimage, uint256 remoteIndex) = _preimageWithInvalidRemoteLeg(predicted);
        // Redeclare the co-leg's source as a chain id never registered in the (real) registry.
        preimage.legSourceChainIds[remoteIndex] = phantomChainId;

        uint256 balanceBefore = IERC20(l2Token).balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainNotRegistered.selector, phantomChainId));
        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _atomicAttributes(preimage, salt)
        );
        assertEq(
            IERC20(l2Token).balanceOf(address(this)),
            balanceBefore,
            "the burn must be unwound with the rejected send"
        );
    }

    /// @notice The `atomicBundle` attribute is recognized in ANY position of the attributes array —
    /// here as the FIRST attribute (every other test passes it after the salt). A position-dependent
    /// parse would silently mishandle the atomic metadata of a legitimately ordered send.
    function test_atomicSend_AtomicAttributeFirstInArray() public {
        _setUpAtomicStack();
        AtomicFlowManager manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);

        address l2Token = initializeTokenByDeposit();
        bytes32 salt = keccak256("atomic attribute-order salt");
        InteropCallStarter[] memory calls = _tokenCallStarter(l2Token, TRANSFER_AMOUNT);

        bytes32 predicted = _predictBundleHash(calls, salt);
        (AtomicFlowPreimage memory preimage, ) = _preimageWithInvalidRemoteLeg(predicted);

        // Same attributes as `_atomicAttributes`, in reverse order: `atomicBundle` first.
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodeCall(IERC7786Attributes.atomicBundle, (preimage, 0));
        attrs[1] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (salt));

        bytes32 bundleHash = l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            attrs
        );

        assertEq(bundleHash, predicted, "attribute order must not change the bundle hash");
        assertEq(
            uint256(manager.legState(_flowIdOf(preimage), bundleHash)),
            uint256(LegState.Committed),
            "the leg must be Committed regardless of the atomic attribute's position"
        );
    }
}
