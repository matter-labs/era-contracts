// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState, AtomicFlow, AtomicFlowPreimage, ImtProof, AtomicFinalityProof} from "./IAtomicInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain coordinator for the atomic interop flow: `append` commits a source leg at send
/// time, `accept` records the destination's acceptance of a leg (accepted flows), and the last of this
/// chain's steps in an accepted flow inserts its participation value; `requireFlowFinalized`
/// gates atomic execution on the destination, and `authorizeRefund`/`claimRefund` implement the timeout
/// path. Never custodies funds. Deployed as an
/// L2 predeploy (no constructor). See {protocol-docs/atomicity/flow.md#the-atomicflowmanager}.
interface IAtomicFlowManager {
    /// @notice Emitted when a source leg is committed on this chain (no IMT leaf of its own).
    event FlowLegCommitted(bytes32 indexed flowId, bytes32 indexed bundleHash);
    /// @notice Emitted when this chain, as a leg's destination, accepts it (no IMT leaf of its own).
    event FlowAccepted(bytes32 indexed flowId, bytes32 indexed bundleHash);
    /// @notice Emitted when this chain inserts its participation value for an accepted flow into its IMT.
    event FlowParticipated(bytes32 indexed flowId, uint64 deadline, uint256 leafIndex);
    /// @notice Emitted per source leg marked `Revertable` by a timeout proof.
    event FlowRefundAuthorized(bytes32 indexed flowId, bytes32 indexed bundleHash);
    /// @notice Emitted when a `Revertable` leg's refund claim is consumed. Funds move only for the
    /// bundle's recoverable calls — possibly none (see
    /// {protocol-docs/atomicity/recovery.md#nothing-recoverable--no-op-claim}).
    event FlowRefunded(bytes32 indexed flowId, bytes32 indexed bundleHash);

    /// @notice Records an atomic source leg: recomputes `flowId` from the supplied preimage, verifies
    /// the committing bundle is one of the flow's legs, declared from this chain to the bundle's
    /// destination, and that every chain of the flow passes this chain's receive filter
    /// ({protocol-docs/interop-gating.md#receive-filter}), then inserts this chain's participation value if
    /// this was its last step. State `Unset -> Committed`. Callable only by the {InteropCenter}.
    /// @dev Taking the full preimage (not an opaque `flowId`) is what couples the committed leg to its
    /// flow; a wrong or stale preimage reverts the whole send instead of stranding the burned funds.
    /// See {protocol-docs/atomicity/flow.md#1-atomic-send-append}.
    /// @param _bundleHash `keccak256(interopBundleBytes)` of this leg (chain-specific via the bundle's
    /// own `sourceChainId` field).
    /// @param _destinationChainId The bundle's destination chain.
    /// @param _lowNullifierIndex The low-nullifier slot for the participation value, if this call inserts it
    /// (from the IMT engine).
    /// @param _flowPreimage The full `flowId` preimage; must be {ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED}.
    function append(
        bytes32 _bundleHash,
        uint256 _destinationChainId,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external;

    /// @notice Records this chain's acceptance of an accepted flow's leg: recomputes `flowId`, verifies the
    /// bundle is a leg declared from the bundle's source to this chain and that every chain of the flow
    /// passes this chain's receive filter, then inserts this chain's participation value if this was its
    /// last step. State `Unset -> Accepted`. Callable only by the {InteropHandler}. See
    /// {protocol-docs/atomicity/acceptance.md}.
    /// @param _bundleHash `keccak256(interopBundleBytes)` of the accepted leg.
    /// @param _sourceChainId The bundle's source chain.
    /// @param _lowNullifierIndex The low-nullifier slot for the participation value, if this call inserts it
    /// (from the IMT engine).
    /// @param _flowPreimage The full `flowId` preimage; must be {ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED}.
    function accept(
        bytes32 _bundleHash,
        uint256 _sourceChainId,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external;

    /// @notice Reverts unless every commitment of the flow was made in time (per-commitment IMT inclusion
    /// proofs — see the {AtomicInteropProof} library header): each leg committed on its source or, for an
    /// accepted flow, each participating chain's participation value, all on chains this chain accepts
    /// ({protocol-docs/interop-gating.md#receive-filter}); and the executing bundle is a leg of the flow.
    /// Callable only by the {InteropHandler}.
    /// @param _executingBundleHash The bundle hash the handler is about to execute.
    /// @param _finality The flow definition + per-commitment inclusion proofs.
    function requireFlowFinalized(bytes32 _executingBundleHash, AtomicFinalityProof calldata _finality) external view;

    /// @notice Mark this chain's committed source legs `Revertable` for a flow that can no longer
    /// finalize, proven by a timeout for one commitment (a leg's commit or, for an accepted flow, a chain's
    /// participation) on a chain this chain accepts ({protocol-docs/interop-gating.md#receive-filter}).
    /// Permissionless.
    /// @param _flow The flow definition ({AtomicFlow}).
    /// @param _missingLegIndex Index into `_flow.preimage.legBundleHashes` of a leg that cannot complete: its
    /// commit is missing (source-only flows), or the participation of its source or destination chain
    /// (accepted flows).
    /// @param _absence Timeout proof for the missing commitment's value (see
    /// {AtomicInteropProof.verifyTimeoutAbsence}), against the tree of the chain it names: the leg's source,
    /// or for an accepted flow either of its chains.
    function authorizeRefund(AtomicFlow calldata _flow, uint256 _missingLegIndex, ImtProof calldata _absence) external;

    /// @notice Claims a `Revertable` leg's refund (best-effort — see
    /// {protocol-docs/atomicity/recovery.md#non-guarantees}): reverses the bundle's asset-router calls
    /// (re-minting each burned asset to its depositor) and refunds a direct call's base-token `value`.
    /// Permissionless. State `Revertable -> Reverted`.
    /// @param _flowId The flow the leg belongs to.
    /// @param _bundle The ABI-encoded {InteropBundle} of the source leg (hashes to the committed leg).
    function claimRefund(bytes32 _flowId, bytes calldata _bundle) external;

    /// @notice Current state of a `(flowId, bundleHash)` on this chain: its source-leg lifecycle, or
    /// `Accepted` once this chain, as the leg's destination, accepted it.
    function legState(bytes32 _flowId, bytes32 _bundleHash) external view returns (LegState);

    /// @notice One-time L2 initialization performed by the genesis upgrade; sets the L1 chain ID
    /// every flow's settlement layer is checked against.
    function initL2(uint256 _l1ChainId) external;

    /// @notice The interop commitment tree this manager inserts into.
    function commitmentTree() external view returns (address);

    /// @notice The interop center authorized to call `append`.
    function interopCenter() external view returns (address);

    /// @notice The interop handler authorized to call `accept` and `requireFlowFinalized`.
    function interopHandler() external view returns (address);
}
