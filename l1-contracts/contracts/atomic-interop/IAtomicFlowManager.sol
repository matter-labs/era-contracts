// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState, AtomicFlow, AtomicFlowPreimage, ImtProof, AtomicFinalityProof} from "./IAtomicInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain coordinator for the atomic interop flow: `append` commits a source leg at send
/// time, `requireFlowFinalized` gates atomic execution on the destination, and
/// `authorizeRefund`/`claimRefund` implement the timeout path. Never custodies funds. Deployed as an
/// L2 predeploy (no constructor). See {protocol-docs/atomic-interop.md#flow}.
interface IAtomicFlowManager {
    /// @notice Emitted when a source leg is committed to this chain's IMT.
    event FlowCommitted(bytes32 indexed flowId, bytes32 indexed bundleHash, uint64 deadline, uint256 leafIndex);
    /// @notice Emitted per source leg marked `Revertable` by a timeout proof.
    event FlowRefundAuthorized(bytes32 indexed flowId, bytes32 indexed bundleHash);
    /// @notice Emitted when a `Revertable` leg's burned funds are recovered.
    event FlowRefunded(bytes32 indexed flowId, bytes32 indexed bundleHash);

    /// @notice Records an atomic source leg: recomputes `flowId` from the supplied preimage, verifies
    /// the committing bundle is one of the flow's legs (declared with this chain as its source) and
    /// that every other leg declares an interop-registered source chain, then inserts the leg's commit
    /// value into the interop IMT. State `Unset -> Committed`. Callable only by the {InteropCenter}.
    /// @dev Taking the full preimage (not an opaque `flowId`) is what couples the committed leg to its
    /// flow; a wrong or stale preimage reverts the whole send instead of stranding the burned funds.
    /// See {protocol-docs/atomic-interop.md#flow}.
    /// @param _bundleHash `keccak256(abi.encode(sourceChainId, interopBundleBytes))` of this leg.
    /// @param _lowNullifierIndex The low-nullifier slot for the commit value (from the IMT engine).
    /// @param _flowPreimage The full `flowId` preimage ({AtomicFlowPreimage}).
    function append(
        bytes32 _bundleHash,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external;

    /// @notice Reverts unless every leg of the flow was committed in time (per-leg IMT inclusion
    /// proofs — see the {AtomicInteropProof} library header) and the executing bundle is a leg of the
    /// flow. Callable only by the {InteropHandler}.
    /// @param _executingBundleHash The bundle hash the handler is about to execute.
    /// @param _finality The flow definition + per-leg inclusion proofs.
    function requireFlowFinalized(bytes32 _executingBundleHash, AtomicFinalityProof calldata _finality) external view;

    /// @notice Mark this chain's committed source legs `Revertable` for a flow that can no longer
    /// finalize, proven by a timeout for one leg. Permissionless.
    /// @param _flow The flow definition ({AtomicFlow}). The absence proof must target
    /// `_flow.preimage.legSourceChainIds[_missingLegIndex]`.
    /// @param _missingLegIndex Index into `_flow.preimage.legBundleHashes` of the leg proven absent.
    /// @param _absence Timeout proof for the missing leg's commit value
    /// (see {AtomicInteropProof.verifyTimeoutAbsence}).
    function authorizeRefund(AtomicFlow calldata _flow, uint256 _missingLegIndex, ImtProof calldata _absence) external;

    /// @notice Recovers the burned source funds for a `Revertable` leg by reversing the bundle's
    /// asset-router calls (re-minting each burned asset to its depositor). Permissionless. State
    /// `Revertable -> Reverted`.
    /// @param _flowId The flow the leg belongs to.
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
