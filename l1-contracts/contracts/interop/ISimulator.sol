// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {L2Message} from "../common/Messaging.sol";

/// @notice One step of a simulation plan, invoked by `runPlan` as a regular `target.call(data)`.
/// State changes from steps persist; only the L2->L1 emission inside `_sendBundleToL1` is
/// sim-gated.
struct PlanStep {
    address target;
    bytes data;
}

/// @notice A peer chain's simulation log + Merkle inclusion proof against
/// `L2InteropRootStorage[chainId, blockOrBatchNumber]`. Submitted to
/// `recordFinalitySignal` so the source chain can verify each peer ran its plan and to
/// check that the bundle graph closes (every destination referenced is in the participating set).
struct PeerSimLog {
    uint256 chainId;
    uint256 blockOrBatchNumber;
    L2Message message;
    uint256 messageIndex;
    bytes32[] merkleProof;
}

/// @notice Lifecycle of a flow on a single chain.
/// `None`       — never seen on this chain.
/// `Initiated`  — flow registered, awaiting a finality decision. Asset custody (if any) is held
///                separately by `FlowAssetEscrow`.
/// `Finalized`  — finality decision observed; downstream contracts (e.g. the escrow) may
///                release locked assets.
/// `Reverted`   — deadline passed without finality; downstream contracts may refund.
enum FlowState {
    None,
    Initiated,
    Finalized,
    Reverted
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain coordinator for cross-chain async-atomic flows.
///
/// The Simulator owns flow lifecycle only. It does not custody assets, does not pull tokens,
/// and does not call the asset escrow. Callers ("registrars" — typically EOAs or pool contracts)
/// register a flow with `registerFlow`, run the on-chain plan via `simulate`, and either record
/// finality (`recordFinalitySignal`) or wait for the deadline. Asset custody is delegated to
/// `FlowAssetEscrow`, which reads the Simulator's `isFinalized` / `isReverted` views to decide
/// when to release or refund the assets it holds.
///
/// On the source chain, once the off-chain simulation has been linked, `recordFinalitySignal`
/// records the fact `(L2_SIMULATOR_ADDR, flowId)` in the `IMTFactRecorder`. The recorder
/// publishes the new IMT root to L1 via a sendToL1 log — this is the safety-net used by
/// `revertExpired` if the happy-path interop delivery never lands.
///
/// After recording, the source chain optionally calls `dispatchFinality` once per participating
/// destination, which emits a per-destination L2->L1 message via the system L1Messenger as a
/// courtesy notification. Destinations finalize via `finalize(flowId, root, leaf, leafIndex,
/// proof)` against the source's IMT root snapshot; the L1Messenger log is just a trigger so
/// destinations know the source has acted.
///
/// `revertExpired(flowId, root, lowLeaf, ...)` is the freeze path: after the deadline, prove
/// non-inclusion against the source's IMT root and mark the flow as reverted.
///
/// Optional binding for user contracts: a flow can be bound to one or more bundle hashes via
/// `attachBundleToFlow`. Any contract may then call `requireBundleFinalized(bundleHash)` to
/// gate its own behaviour on that flow's finality.
interface ISimulator {
    event FlowRegistered(bytes32 indexed flowId, address indexed registrar, uint64 deadline);
    event FinalitySignal(bytes32 indexed flowId, bytes32 newRoot, uint256 newLeafIndex);
    event FinalityDispatched(bytes32 indexed flowId, uint256 indexed destinationChainId, bytes32 messageHash);
    event FlowFinalized(bytes32 indexed flowId);
    event FlowReverted(bytes32 indexed flowId);
    event BundleAttachedToFlow(bytes32 indexed flowId, bytes32 indexed bundleHash);
    event SimulatedBundleRecorded(bytes32 indexed flowId, uint256 indexed simIndex, bytes32 verifyHash);
    event SimulationLogPublished(bytes32 indexed flowId, uint256 bundleCount);

    /// @notice Register a flow on this chain so it can be simulated, finalized, or reverted.
    /// @dev `msg.sender` is recorded as the registrar — only they may call `simulate` or
    /// `dispatchFinality` for this flow. The Simulator does not touch assets; callers should
    /// have already escrowed any locks via `FlowAssetEscrow.lock` before (or after) registering.
    function registerFlow(bytes32 _flowId, uint64 _deadline) external;

    /// @notice Record the finality decision for `_flowId` on this chain. This is the source
    /// chain's single canonical step after simulation + linking succeed; it:
    ///   1. verifies linking — every participating peer chain provides one `PeerSimLog`
    ///      (their `Simulator.simulate` summary) with a Merkle inclusion proof against
    ///      `L2InteropRootStorage[peer.chainId, blockOrBatchNumber]`,
    ///   2. confirms each peer log's `sender == L2_SIMULATOR_ADDR` and `flowId` matches,
    ///   3. checks closure: every destination chainId mentioned by *any* sim log (local or
    ///      peer) is in the participating set `{self} ∪ {peer chainIds}`,
    ///   4. records the finality fact in the local `IMTFactRecorder`,
    ///   5. flips the local flow state to `Finalized` (no separate self-finalize needed),
    ///   6. emits one L2->L1 finality notification per peer chain via the system
    ///      `L1Messenger`. Destinations observe these as a trigger to call `finalize(...)`
    ///      with the source's IMT inclusion proof.
    /// Pass an empty `_peerLogs` for a single-chain flow.
    function recordFinalitySignal(
        bytes32 _flowId,
        uint256 _lowLeafIndex,
        PeerSimLog[] calldata _peerLogs
    ) external returns (bytes32 newRoot, uint256 newLeafIndex);

    /// @notice Fallback finalize path: prove inclusion of the finality fact in a source chain's
    /// IMT root and mark the flow as `Finalized`. Asset custody (if any) lives in
    /// `FlowAssetEscrow`, which observes this state to release locked assets.
    function finalize(
        bytes32 _flowId,
        bytes32 _imtRoot,
        IMTLeaf calldata _leaf,
        uint256 _leafIndex,
        bytes32[] calldata _proof
    ) external;

    /// @notice After the deadline, prove non-inclusion of the finality fact in the source
    /// chain's IMT root and mark the flow as `Reverted`. `FlowAssetEscrow.refund` consumes
    /// this state to return locked assets to the depositor.
    function revertExpired(
        bytes32 _flowId,
        bytes32 _imtRoot,
        IMTLeaf calldata _lowLeaf,
        uint256 _lowLeafIndex,
        bytes32[] calldata _lowLeafProof
    ) external;

    /// @notice Authorization view used by `PrivateInteropHandler`. If the bundle hash is not
    /// attached to any flow, returns silently (the public path is unaffected). If it is, reverts
    /// unless the bound flow is `Finalized`.
    function requireBundleFinalized(bytes32 _bundleHash) external view;

    /// @notice Public getter auto-generated from the `flows` storage mapping. Returns the
    /// flow's state (`FlowState` enum, accessed as a `uint8` from non-Solidity callers),
    /// deadline, and registrar address. Callers compare `state` directly against
    /// `FlowState.Finalized` / `FlowState.Reverted` rather than going through dedicated
    /// boolean views.
    function flows(bytes32 _flowId) external view returns (FlowState state, uint64 deadline, address registrar);

    /// @notice Public getter auto-generated from the `bundleFlow` storage mapping.
    /// Returns the flow id this bundle hash is bound to, or `bytes32(0)` if unbound.
    function bundleFlow(bytes32 _bundleHash) external view returns (bytes32);

    /*//////////////////////////////////////////////////////////////
                        Simulation phase (per spec)
    //////////////////////////////////////////////////////////////*/

    /// @notice Run the plan and commit to the set of interop bundles it's expected to trigger.
    /// Two modes:
    ///   1. **Pre-staged** (`_expectedBundleBytes` non-empty): the Simulator pre-stages
    ///      `encodeInteropBundleHash(block.chainid, _expectedBundleBytes[i])` in transient
    ///      storage; if the plan tries to send a bundle whose hash isn't in the pre-staged
    ///      set, simulation reverts. Use when the plan's bundles are predictable off-chain.
    ///   2. **Auto-record** (`_expectedBundleBytes` empty): the plan's first outbound
    ///      bundle is captured (hash + dest chain id) by `checkSimulation` writes to
    ///      transient storage; the outer frame commits after `runPlan` reverts. Use for
    ///      plans whose bundle bytes can't be predicted off-chain (e.g. indirect calls
    ///      through `AssetRouter`).
    /// After the plan returns, each recorded hash is stored on-chain and emitted via
    /// `L1Messenger.sendToL1` as this chain's durable simulation log.
    /// @dev Only the flow's registrar may simulate; the flow must be `Initiated` and unexpired.
    /// Returns the committed bundle hashes AND the raw bundle bytes (pre-staged or
    /// auto-recorded). Off-chain callers can use `callStatic` to dry-run the plan and
    /// capture both without committing — the bytes are useful for downstream chains whose
    /// simulate plan needs to apply this bundle as input.
    /// @param _inboundBundleHashes Bundle hashes from upstream chains that this chain's
    ///        plan will mock-apply (via `simulateApplyBundle`) and that destination-side
    ///        gating (`requireBundleFinalized`) needs bound to this flow id. Attached in
    ///        the outer (non-reverting) frame before `runPlan` so the binding survives the
    ///        sentinel revert. Each hash must not already be bound to a different flow.
    function simulate(
        bytes32 _flowId,
        PlanStep[] calldata _steps,
        bytes[] calldata _expectedBundleBytes,
        bytes32[] calldata _inboundBundleHashes
    ) external returns (bytes32[] memory bundleHashes, bytes[] memory bundleBytes);

    /// @notice External self-call target for `simulate`. Loops `step.target.call(step.data)`.
    /// Plan steps execute as regular calls — state changes persist; only the L2->L1 emission
    /// in `InteropCenter._sendBundleToL1` is sim-gated.
    function runPlan(bytes32 _flowId, PlanStep[] calldata _steps) external;

    /// @notice Auto-detect callback used by `InteropCenter._sendBundle`. Behaviour:
    ///   - returns `false` when no simulation is active (caller proceeds normally);
    ///   - returns `true` when a simulation is active and `_bundleHash` matches a pre-staged
    ///     expected hash;
    ///   - reverts with `UnexpectedSimulatedBundle` when a simulation is active in pre-staged
    ///     mode and `_bundleHash` isn't in the expected set;
    ///   - in auto-record mode (no pre-staged hashes), captures `_bundleHash`, `_destChainId`,
    ///     and `_bundleBytes` to transient storage so the outer `simulate` frame can return
    ///     them after `runPlan` reverts.
    function checkSimulation(
        bytes32 _bundleHash,
        uint256 _destChainId,
        bytes calldata _bundleBytes
    ) external returns (bool);

    /// @notice The on-chain durable record of bundle hashes published by `simulate` for a
    /// given flow, in the order they were pre-staged or auto-recorded.
    function simulatedBundleHashAt(bytes32 _flowId, uint256 _index) external view returns (bytes32);

    function simulatedBundleCount(bytes32 _flowId) external view returns (uint256);

    /// @notice True after `simulate` has completed successfully for `_flowId` on this chain.
    function isFlowSimulated(bytes32 _flowId) external view returns (bool);

    /// @notice True iff a `simulate` call is currently in progress. Backed by transient
    /// storage set in `simulate`'s outer frame before `runPlan` and cleared after — so it
    /// stays true throughout the plan's call tree (including any reverted sub-calls).
    /// Downstream contracts (e.g. `FlowAssetEscrow`) use this to detect "called from a
    /// Simulator-orchestrated plan, not a real on-chain action" and relax their gates
    /// accordingly. The runPlan revert rolls back state changes regardless.
    function isSimulating() external view returns (bool);
}
