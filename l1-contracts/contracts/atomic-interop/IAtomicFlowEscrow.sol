// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SendSpec, SpecState, ImtInclusionProof, ImtNonInclusionProof} from "./IAtomicInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain escrow for the L1-free atomic interop flow.
///
/// Structurally mirrors the L1-coordinated `L2FlowEscrow` (same `commitSend` / `authorize` /
/// `execute` / refund split and the same asset routing through the L2 asset router + native token
/// vault), but the authorization step is gated by **IMT proofs** against an imported global
/// interop-IMT root instead of an aliased L1 linker call:
///
///   1. `commitSend` — the source depositor locks tokens and the spec's commit value is inserted
///      into the chain's indexed interop IMT. When the batch settles, the operator exposes the IMT
///      root on L1.
///   2. `authorize` — once a caller can prove (against an imported global root) that *every* spec of
///      the flow was committed before the deadline, the specs relevant to this chain become
///      `Executable`. Permissionless.
///   3. `execute` — performs the asset op via AR/NTV: burn on the source, mint on the destination.
///   4. `authorizeRefund` / `claimRefund` — the timeout path, gated by an O(log n) non-inclusion
///      proof.
///
/// `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`,
/// `specHash = keccak256(abi.encode(spec))`; both arrays strictly ascending.
///
/// Deployed in L2 userspace (CREATE2), so it has no constructor — wiring is done in `initialize`.
interface IAtomicFlowEscrow {
    event FlowCommitted(bytes32 indexed flowId, bytes32 indexed specHash, address indexed depositor, uint256 leafIndex);
    event FlowAuthorized(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowExecuted(bytes32 indexed flowId, bytes32 indexed specHash, bool isSource);
    event FlowRefundAuthorized(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowRefunded(bytes32 indexed flowId, bytes32 indexed specHash, address indexed depositor);

    /// @notice Lock `_spec.amount` of `_spec.originToken` from `_spec.depositor` and insert the
    /// spec's commit value into the chain's indexed interop IMT. Caller must be `_spec.depositor`;
    /// `_spec.originChainId` must be this chain. State `Unset -> Committed`.
    /// @param _lowNullifierIndex The low-nullifier slot for the commit value (from the IMT engine).
    function commitSend(bytes32 _flowId, SendSpec calldata _spec, uint256 _lowNullifierIndex) external;

    /// @notice Mark this chain's specs of a flow `Executable`, once every spec is proven committed in
    /// time. Permissionless. Valid prior states: `Unset` (destination) or `Committed` (source).
    /// @param _specs All specs of the flow, sorted ascending by `specHash`.
    /// @param _chainIds The flow's participant chain ids, strictly ascending.
    /// @param _deadline The flow deadline (compared against imported L1 timestamps).
    /// @param _proofs Inclusion proofs aligned 1:1 with `_specs` (each against its origin chain).
    function authorize(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        ImtInclusionProof[] calldata _proofs
    ) external;

    /// @notice Settle one leg. Anyone may call with the full `SendSpec`. Requires `Executable`; burns
    /// via AR/NTV on the source, mints via AR/NTV on the destination. State `Executable -> Executed`.
    function execute(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Mark this chain's source specs `Revertable` for a flow that can no longer finalize,
    /// proven by a non-inclusion proof for one spec across the deadline boundary. Permissionless.
    /// @param _missingSpecIndex Index into `_specs` of the spec proven absent.
    function authorizeRefund(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        uint256 _missingSpecIndex,
        ImtNonInclusionProof calldata _proof
    ) external;

    /// @notice Refund the locked tokens to `_spec.depositor`. Requires `Revertable`.
    /// State `Revertable -> Reverted`.
    function claimRefund(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Current state of a `(flowId, specHash)` on this chain.
    function specState(bytes32 _flowId, bytes32 _specHash) external view returns (SpecState);

    /// @notice The interop commitment tree this escrow inserts into.
    function commitmentTree() external view returns (address);

    /// @notice The global-root importer this escrow verifies proofs against.
    function importer() external view returns (address);

    /// @notice The L2 asset router used for burns/mints.
    function assetRouter() external view returns (address);

    /// @notice The L2 native token vault used for source-side allowances.
    function nativeTokenVault() external view returns (address);
}
