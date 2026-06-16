// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {InteropCallStarter, MessageInclusionProof} from "../common/Messaging.sol";
import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice One asset lock contributed to a flow.
/// `token == address(0)` denotes the chain's native asset (msg.value).
struct Lock {
    address beneficiary;
    address token;
    uint256 amount;
}

/// @notice The cross-chain bundle the escrow will dispatch on behalf of the depositor at
/// `dispatchToInteropCenter` time. Stored verbatim alongside the locks so the user records the
/// outbound interop in the same call that funds it. Use empty `callStarters` for chains that
/// only participate as receivers (no outbound bundle).
/// @dev `destinationChainId` is the ERC-7930 encoding consumed by `IInteropCenter.sendBundle`;
/// `bundleAttributes` is the raw ERC-7786 attribute set passed alongside it.
struct Dispatch {
    bytes destinationChainId;
    InteropCallStarter[] callStarters;
    bytes[] bundleAttributes;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Custodian for assets escrowed under a flow id, plus the outbound dispatch the
/// escrow forwards to the local `InteropCenter` during simulation.
///
/// User-facing: an EOA (or a contract acting on a user's behalf) calls `lock` with the assets
/// to be escrowed and the bundle the simulation plan should dispatch. The escrow doesn't know
/// or care about flow lifecycle — it asks the `Simulator` whether the flow is `Finalized`
/// (release) or `Reverted` (refund) and acts accordingly. There is no explicit authority gate;
/// the per-flow `Settlement` flag prevents double-spends.
interface IFlowAssetEscrow {
    event Locked(bytes32 indexed flowId, address indexed depositor);
    event Dispatched(bytes32 indexed flowId, bytes32 bundleHash);
    event Released(bytes32 indexed flowId);
    event Refunded(bytes32 indexed flowId, address indexed depositor);

    /// @notice Take custody of `_locks` for `_flowId` and record `_dispatch` for later forwarding
    /// to the `InteropCenter` during the simulation phase. `msg.sender` is the depositor and is
    /// recorded for refund routing. For native locks the escrow expects `msg.value` to equal the
    /// sum of native amounts; ERC20 amounts must be approved on this contract beforehand.
    /// @dev A flow can only be locked once. Pass an empty `_dispatch.callStarters` for chains
    /// that have no outbound bundle.
    function lock(bytes32 _flowId, Lock[] calldata _locks, Dispatch calldata _dispatch) external payable;

    /// @notice Forward the recorded `Dispatch` to `IInteropCenter.sendBundle`. Two callers:
    ///   1. `Simulator.runPlan` during simulate (msg.sender == `L2_SIMULATOR_ADDR`) — the
    ///      InteropCenter's sim-mode hook captures the bundle hash and the outer `runPlan`
    ///      reverts roll the side effects back; bypasses the finality gate.
    ///   2. Anyone, after the local flow is `Finalized` — does the real on-chain dispatch.
    ///      Approves `L2NativeTokenVault` for any ERC20 locks before the call so indirect-call
    ///      bundles (e.g. AssetRouter bridging) can pull tokens from the escrow.
    /// Returns `bytes32(0)` when there's no outbound bundle for this flow.
    function dispatchToInteropCenter(bytes32 _flowId) external returns (bytes32 bundleHash);

    /// @notice Send each recorded lock to its `beneficiary`. Reverts unless the local Simulator
    /// reports the flow as `Finalized`. One-shot: a flow can only be released or refunded once.
    function release(bytes32 _flowId) external;

    /// @notice Return every recorded lock to the original depositor. Reverts unless the local
    /// Simulator reports the flow as `Reverted` (i.e. timed out without finality). One-shot.
    function refund(bytes32 _flowId) external;

    /// @notice View accessor used by tests and off-chain consumers.
    function getLocks(bytes32 _flowId) external view returns (Lock[] memory);

    /// @notice Auto-generated getter for the `depositors` storage mapping.
    function depositors(bytes32 _flowId) external view returns (address);

    /// @notice Simulation-only: apply an inbound bundle to local state so subsequent plan
    /// steps observe the post-receipt state (e.g. tokens minted by `AssetRouter.finalizeDeposit`
    /// before the swap pool dispatches its outbound bundle). Restricted to
    /// `msg.sender == L2_SIMULATOR_ADDR`; intended to be called only from inside
    /// `Simulator.runPlan`, which reverts at the end so all state changes here roll back.
    /// Bypasses the atomicity gate (the flow may still be `Initiated` during simulation).
    function simulateApplyBundle(bytes calldata _bundle, MessageInclusionProof calldata _proof) external;

    /// @notice Single destination-side claim: finalize the local flow against the source's
    /// IMT root + inclusion proof (no-op if already `Finalized`), verify the bundle is
    /// attached to this flow, and execute it via `InteropHandler.executeBundle`. Atomicity
    /// guarantees that finalize and bundle execution happen together — the IMT proof
    /// commits the flow as decided on the source, and the bundle inclusion proof commits
    /// the bundle as actually emitted there.
    /// @dev To gate via the Simulator, the source-side dispatch must include this escrow's
    /// address as the bundle's `executionAddress`, and the destination-side flow registrar
    /// must call `Simulator.attachBundleToFlow` with the predicted bundle hash before this
    /// call. Bundles not attached to any flow are NOT gated (`requireBundleFinalized`
    /// returns silently in that case) — the public path is unaffected.
    function finalizeAndExecute(
        bytes32 _flowId,
        bytes32 _imtRoot,
        IMTLeaf calldata _imtLeaf,
        uint256 _imtLeafIndex,
        bytes32[] calldata _imtProof,
        bytes calldata _bundle,
        MessageInclusionProof calldata _bundleProof
    ) external;
}
