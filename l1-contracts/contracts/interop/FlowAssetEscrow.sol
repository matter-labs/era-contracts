// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IFlowAssetEscrow, Lock, Dispatch} from "./IFlowAssetEscrow.sol";
import {ISimulator, FlowState} from "./ISimulator.sol";
import {IInteropCenter} from "./IInteropCenter.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {InteropBundle, InteropCallStarter, MessageInclusionProof} from "../common/Messaging.sol";
import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SIMULATOR_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {EmptyAddress, Unauthorized} from "../common/L1ContractErrors.sol";
import {LockAmountZero, NativeValueMismatch, NativeTransferFailed, FlowMustHaveLocks} from "./SimulatorErrors.sol";

error EscrowFlowAlreadyLocked(bytes32 flowId);
error EscrowFlowAlreadySettled(bytes32 flowId);
error EscrowFlowNotLocked(bytes32 flowId);
error EscrowFlowNotFinalized(bytes32 flowId);
error EscrowFlowNotReverted(bytes32 flowId);
error EscrowUnexpectedNativeValue(uint256 value);

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `IFlowAssetEscrow` for the protocol-level description.
/// @dev User-callable. The escrow takes custody of locked assets at `lock` time, stores the
/// outbound `Dispatch` (so the simulation plan can forward it to `InteropCenter` from inside
/// `runPlan`), and consults the local `Simulator` to decide whether `release` or `refund` may
/// proceed. Settlement is one-shot per flow id.
contract FlowAssetEscrow is IFlowAssetEscrow {
    using SafeERC20 for IERC20;

    enum Settlement {
        None,
        Locked,
        Dispatched,
        Released,
        Refunded
    }

    /// @dev Locks recorded for `_flowId`, in the insertion order the depositor passed to `lock`.
    mapping(bytes32 flowId => Lock[]) internal _locks;

    /// @dev Outbound bundle the depositor wants the simulation plan to forward via
    /// `dispatchToInteropCenter`. Empty `callStarters` means "no outbound bundle for this chain".
    mapping(bytes32 flowId => Dispatch) internal _dispatches;

    /// @dev `msg.sender` recorded at `lock` time. Refunds route here.
    mapping(bytes32 flowId => address) public depositors;

    /// @dev Per-flow settlement state. Locked at `lock` time, transitions to Dispatched,
    /// Released, or Refunded exactly once. The Simulator's flow state is the authoritative
    /// finality decision; this flag only prevents double-spends.
    mapping(bytes32 flowId => Settlement) public settlement;

    /// @inheritdoc IFlowAssetEscrow
    function lock(bytes32 _flowId, Lock[] calldata _locksIn, Dispatch calldata _dispatch) external payable {
        if (settlement[_flowId] != Settlement.None) revert EscrowFlowAlreadyLocked(_flowId);
        if (_locksIn.length == 0) revert FlowMustHaveLocks();

        settlement[_flowId] = Settlement.Locked;
        depositors[_flowId] = msg.sender;

        uint256 totalNative;
        uint256 locksLen = _locksIn.length;
        for (uint256 i; i < locksLen; ++i) {
            Lock calldata lk = _locksIn[i];
            if (lk.amount == 0) revert LockAmountZero();
            if (lk.beneficiary == address(0)) revert EmptyAddress();

            _locks[_flowId].push(lk);

            if (lk.token == address(0)) {
                totalNative += lk.amount;
            } else {
                IERC20(lk.token).safeTransferFrom(msg.sender, address(this), lk.amount);
            }
        }
        if (msg.value != totalNative) revert NativeValueMismatch(totalNative, msg.value);

        // Persist dispatch verbatim (including empty `callStarters` for receive-only chains).
        // Legacy codegen can't whole-array copy calldata structs with nested dynamic types into
        // storage, so we do it field-by-field manually.
        Dispatch storage stored = _dispatches[_flowId];
        stored.destinationChainId = _dispatch.destinationChainId;
        uint256 csLen = _dispatch.callStarters.length;
        for (uint256 i; i < csLen; ++i) {
            stored.callStarters.push();
            InteropCallStarter storage cs = stored.callStarters[i];
            cs.to = _dispatch.callStarters[i].to;
            cs.data = _dispatch.callStarters[i].data;
            uint256 attrsLen = _dispatch.callStarters[i].callAttributes.length;
            for (uint256 j; j < attrsLen; ++j) {
                cs.callAttributes.push(_dispatch.callStarters[i].callAttributes[j]);
            }
        }
        uint256 baLen = _dispatch.bundleAttributes.length;
        for (uint256 i; i < baLen; ++i) {
            stored.bundleAttributes.push(_dispatch.bundleAttributes[i]);
        }

        emit Locked(_flowId, msg.sender);
    }

    /// @inheritdoc IFlowAssetEscrow
    function dispatchToInteropCenter(bytes32 _flowId) external returns (bytes32 bundleHash) {
        if (settlement[_flowId] != Settlement.Locked) revert EscrowFlowNotLocked(_flowId);

        // Two real-world callers and a simulation context:
        //   (a) `Simulator.runPlan` directly (msg.sender == Simulator) — sim path 1.
        //   (b) Any contract called *transitively* during a Simulator-orchestrated plan,
        //       e.g. a swap pool's callback fired by `InteropHandler.executeBundle` from
        //       inside `simulateApplyBundle`. Detected via `Simulator.isSimulating()` —
        //       sim path 2.
        //   (c) Any caller after the flow is `Finalized` — the real on-chain dispatch.
        // Both sim paths bypass the finality gate; their state mutations are wholesale
        // rolled back by `runPlan`'s sentinel revert. The real path requires Finalized to
        // ensure the bundle never leaves until the flow has cleared the finality fence —
        // otherwise a dispatched bundle could end up unexecutable on the destination if the
        // flow later expires.
        bool inSim = msg.sender == L2_SIMULATOR_ADDR || ISimulator(L2_SIMULATOR_ADDR).isSimulating();
        if (!inSim) {
            (FlowState state, , ) = ISimulator(L2_SIMULATOR_ADDR).flows(_flowId);
            if (state != FlowState.Finalized) revert EscrowFlowNotFinalized(_flowId);
            settlement[_flowId] = Settlement.Dispatched;
        }

        Dispatch storage d = _dispatches[_flowId];
        if (d.callStarters.length == 0) {
            // No outbound bundle for this chain: nothing to forward.
            return bytes32(0);
        }

        // Approve `L2NativeTokenVault` for any ERC20 locks before calling `InteropCenter`.
        // Indirect calls in the bundle (e.g. AssetRouter for cross-chain bridging) pull
        // tokens from the bundle sender (= this escrow). Native locks (token == 0) are
        // forwarded as msg.value below.
        Lock[] storage locks = _locks[_flowId];
        uint256 locksLen = locks.length;
        uint256 totalNative;
        for (uint256 i; i < locksLen; ++i) {
            Lock memory lk = locks[i];
            if (lk.token == address(0)) {
                totalNative += lk.amount;
            } else {
                IERC20(lk.token).safeIncreaseAllowance(L2_NATIVE_TOKEN_VAULT_ADDR, lk.amount);
            }
        }

        bundleHash = IInteropCenter(L2_INTEROP_CENTER_ADDR).sendBundle{value: totalNative}(
            d.destinationChainId,
            d.callStarters,
            d.bundleAttributes
        );
        emit Dispatched(_flowId, bundleHash);
    }

    /// @inheritdoc IFlowAssetEscrow
    function release(bytes32 _flowId) external {
        if (settlement[_flowId] != Settlement.Locked) revert EscrowFlowAlreadySettled(_flowId);
        (FlowState state, , ) = ISimulator(L2_SIMULATOR_ADDR).flows(_flowId);
        if (state != FlowState.Finalized) revert EscrowFlowNotFinalized(_flowId);

        settlement[_flowId] = Settlement.Released;

        Lock[] storage locks = _locks[_flowId];
        uint256 n = locks.length;
        for (uint256 i; i < n; ++i) {
            Lock memory lk = locks[i];
            _payOut(lk.token, lk.beneficiary, lk.amount);
        }
        emit Released(_flowId);
    }

    /// @inheritdoc IFlowAssetEscrow
    function refund(bytes32 _flowId) external {
        if (settlement[_flowId] != Settlement.Locked) revert EscrowFlowAlreadySettled(_flowId);
        (FlowState state, , ) = ISimulator(L2_SIMULATOR_ADDR).flows(_flowId);
        if (state != FlowState.Reverted) revert EscrowFlowNotReverted(_flowId);

        address depositor = depositors[_flowId];
        settlement[_flowId] = Settlement.Refunded;

        Lock[] storage locks = _locks[_flowId];
        uint256 n = locks.length;
        for (uint256 i; i < n; ++i) {
            Lock memory lk = locks[i];
            _payOut(lk.token, depositor, lk.amount);
        }
        emit Refunded(_flowId, depositor);
    }

    /// @inheritdoc IFlowAssetEscrow
    function getLocks(bytes32 _flowId) external view returns (Lock[] memory) {
        return _locks[_flowId];
    }

    /// @inheritdoc IFlowAssetEscrow
    function simulateApplyBundle(bytes calldata _bundle, MessageInclusionProof calldata _proof) external {
        // Restricted to simulation context: only the local Simulator (during runPlan) may
        // mock-apply an inbound bundle. Bypasses the atomicity gate — the flow doesn't need
        // to be `Finalized` because we're inside a self-call that always reverts; any state
        // mutated here (bundle status, balances) is rolled back by `runPlan`'s sentinel.
        if (msg.sender != L2_SIMULATOR_ADDR) revert Unauthorized(msg.sender);
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).executeBundle(_bundle, _proof);
    }

    /// @inheritdoc IFlowAssetEscrow
    function finalizeAndExecute(
        bytes32 _flowId,
        bytes32 _imtRoot,
        IMTLeaf calldata _imtLeaf,
        uint256 _imtLeafIndex,
        bytes32[] calldata _imtProof,
        bytes calldata _bundle,
        MessageInclusionProof calldata _bundleProof
    ) external {
        // Idempotent: if the flow is still `Initiated`, finalize via the IMT proof from the
        // source chain. If already `Finalized` (e.g. on the source itself, where
        // `recordFinalitySignal` flips state directly), the IMT args are unused. Other
        // states fall through to `Simulator.finalize`'s `FlowNotInitiated` revert.
        (FlowState state, , ) = ISimulator(L2_SIMULATOR_ADDR).flows(_flowId);
        if (state != FlowState.Finalized) {
            ISimulator(L2_SIMULATOR_ADDR).finalize(_flowId, _imtRoot, _imtLeaf, _imtLeafIndex, _imtProof);
        }

        // Compute the canonical bundle hash and verify the bundle is bound to this flow on
        // this chain (otherwise `requireBundleFinalized` returns silently — bundles not
        // attached to any flow are NOT gated, preserving the public path).
        InteropBundle memory bundle = abi.decode(_bundle, (InteropBundle));
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundle.sourceChainId, _bundle);
        ISimulator(L2_SIMULATOR_ADDR).requireBundleFinalized(bundleHash);

        IInteropHandler(L2_INTEROP_HANDLER_ADDR).executeBundle(_bundle, _bundleProof);
    }

    function _payOut(address _token, address _to, uint256 _amount) internal {
        if (_token == address(0)) {
            (bool ok, ) = payable(_to).call{value: _amount}("");
            if (!ok) revert NativeTransferFailed(_to, _amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }
}
