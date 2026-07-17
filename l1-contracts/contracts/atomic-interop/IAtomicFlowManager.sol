// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState, AtomicFlow, AtomicFlowPreimage, ImtProof, AtomicFinalityProof} from "./IAtomicInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain coordinator for the **atomic interop** flow. It is *not* an escrow: it
/// never custodies funds. The asset burn happens through the normal interop path
/// ({InteropCenter.sendBundle} -> {L2AssetRouter.initiateIndirectCall}); this contract only
/// coordinates the cross-chain atomicity and the timeout recovery, gated by **IMT proofs** against
/// the interop root the verifying chain imports for a settled source batch (see {AtomicInteropProof}).
///
///   1. `append` — called by the {InteropCenter} when a bundle carries the `atomicBundle` attribute,
///      in place of publishing the bundle to L1. It recomputes `flowId` from the attribute-supplied
///      preimage ({AtomicFlowPreimage}), verifies the committing bundle is one of the flow's legs
///      (with this chain as its declared source), inserts the leg's commit value
///      (`commitValue(flowId, bundleHash)`) into this chain's indexed interop IMT and records the
///      source leg as `Committed`. The burn already happened during `sendBundle`.
///   2. `requireFlowFinalized` — called by the {InteropHandler} from `executeAtomicBundle` in place of
///      the L1-message inclusion proof: it verifies that *every* leg of the flow was committed before
///      the deadline. The handler then executes the bundle (and owns the double-execute guard).
///   3. `authorizeRefund` / `claimRefund` — the timeout path: prove (O(log n) non-inclusion) that a leg
///      can no longer be committed in time, then **recover** the burned source funds to the depositor
///      by asking each burn-producing call's local sender (`InteropCall.from`) to reverse itself via
///      {IAtomicRecoverable.recoverAtomicCall}.
///
/// `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))`,
/// `bundleHash = keccak256(abi.encode(sourceChainId, interopBundleBytes))`. `legBundleHashes` is strictly
/// ascending (canonical order + dedup); `legSourceChainIds` is positionally aligned with it (may repeat,
/// need not be ascending). All legs settle on one `settlementLayerChainId`, so the deadline (a settlement-
/// layer timestamp) is comparable to each batch's `l1Timestamp`.
///
/// Deployed as an L2 predeploy (no constructor).
interface IAtomicFlowManager {
    event FlowCommitted(bytes32 indexed flowId, bytes32 indexed bundleHash, uint64 deadline, uint256 leafIndex);
    event FlowRefundAuthorized(bytes32 indexed flowId, bytes32 indexed bundleHash);
    event FlowRefunded(bytes32 indexed flowId, bytes32 indexed bundleHash);

    /// @notice Record an atomic source leg: recompute `flowId` from the supplied preimage, verify the
    /// committing bundle is one of the flow's legs (declared with this chain as its source), insert the
    /// leg's commit value into the interop IMT and mark it `Committed`. Callable only by the
    /// {InteropCenter}. State `Unset -> Committed`.
    /// @dev Taking the full preimage — rather than an opaque, sender-supplied `flowId` — is what couples
    /// the committed leg to its flow. With an opaque id, a bundle committed under a `flowId` whose
    /// preimage does not contain its hash (e.g. because an upgrade changed the bundle encoding between
    /// the sender's off-chain hash preview and the send) would be stranded forever: it could neither
    /// finalize nor be refunded, since both paths require the leg to be inside the preimage. Here such a
    /// mismatch makes the whole send revert before any state is committed.
    /// @param _bundleHash `keccak256(abi.encode(sourceChainId, interopBundleBytes))` of this leg.
    /// @param _lowNullifierIndex The low-nullifier slot for the commit value (from the IMT engine).
    /// @param _flowPreimage The full `flowId` preimage ({AtomicFlowPreimage}): the flow's deadline,
    /// settlement layer, leg bundle hashes (strictly ascending) and their aligned source chain ids.
    function append(
        bytes32 _bundleHash,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external;

    /// @notice Revert if the flow is not fully committed in time. Callable only by the {InteropHandler}.
    /// Verifies an inclusion proof for every leg against its source chain's IMT (the finality
    /// condition — see the {AtomicInteropProof} library header), recomputes `flowId`, ties each proof
    /// to its source chain and the flow's settlement layer, and asserts the bundle being executed is
    /// a leg of the flow.
    /// @param _executingBundleHash The bundle hash the handler is about to execute.
    /// @param _finality The flow definition + per-leg inclusion proofs.
    function requireFlowFinalized(bytes32 _executingBundleHash, AtomicFinalityProof calldata _finality) external view;

    /// @notice Mark this chain's committed source legs `Revertable` for a flow that can no longer
    /// finalize, proven by a timeout for one leg. Permissionless.
    /// @param _flow The flow definition ({AtomicFlow}); its `flowId` is recomputed from the other fields
    /// and matched. The absence proof for the missing leg must target
    /// `_flow.legSourceChainIds[_missingLegIndex]`.
    /// @param _missingLegIndex Index into `_flow.legBundleHashes` of the leg proven absent.
    /// @param _absence Timeout proof for the missing leg's commit value (the timeout condition —
    /// see {AtomicInteropProof.verifyTimeoutAbsence} and the {AtomicInteropProof} library header).
    function authorizeRefund(AtomicFlow calldata _flow, uint256 _missingLegIndex, ImtProof calldata _absence) external;

    /// @notice Recover the burned source funds for a `Revertable` leg by reversing the bundle's
    /// asset-router calls (re-minting each burned asset to its depositor). Permissionless. State
    /// `Revertable -> Reverted`.
    /// @param _bundle The ABI-encoded {InteropBundle} of the source leg (hashes to the committed leg).
    function claimRefund(bytes32 _flowId, bytes calldata _bundle) external;

    /// @notice Current source-leg state of a `(flowId, bundleHash)` on this chain.
    function legState(bytes32 _flowId, bytes32 _bundleHash) external view returns (LegState);

    /// @notice One-time L2 initialization performed by the genesis upgrade; sets the L1 chain ID
    /// every flow's settlement layer is checked against.
    function initL2(uint256 _l1ChainId) external;

    /// @notice The interop commitment tree this manager inserts into.
    function commitmentTree() external view returns (address);

    /// @notice The interop center authorized to call `append`.
    function interopCenter() external view returns (address);

    /// @notice The interop handler authorized to call `requireFlowFinalized`.
    function interopHandler() external view returns (address);
}
