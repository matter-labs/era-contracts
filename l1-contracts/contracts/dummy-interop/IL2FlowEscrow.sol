// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SendSpec, SpecState} from "./IDummyFlow.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain custodian for the atomic-flow stack.
///
/// Users `commitSend` to lock tokens on the source side and publish a commit log to L1.
/// The L1 linker, once the flow is finalized, dispatches `authorizeFromL1` (storage-only
/// priority tx) to each participating chain. Anyone then calls `execute(flowId, sendSpec)`
/// to perform the actual asset operation — the escrow branches on `block.chainid`: burn
/// into NTV custody on the source, mint the bridged shim on the destination.
///
/// The refund path is symmetric: `authorizeRefundFromL1` enables `claimRefund`. Tokens
/// stay in escrow custody between commit and execute, so refunds are direct local
/// transfers — no NTV involvement.
///
/// The escrow trusts a single canonical L1 linker address, hardcoded into the bytecode as
/// a `constant`. CREATE2-deploying the same bytecode on every L2 with the same salt yields
/// the same escrow address everywhere, so the L1 linker can identify the escrow on any L2
/// by one canonical address.
interface IL2FlowEscrow {
    event FlowCommitted(bytes32 indexed flowId, bytes32 indexed specHash, address indexed depositor);
    event FlowAuthorized(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowExecuted(bytes32 indexed flowId, bytes32 indexed specHash, bool isSource);
    event FlowRefundAuthorized(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowRefunded(bytes32 indexed flowId, bytes32 indexed specHash, address indexed depositor);

    /// @notice Lock `_spec.amount` of `_spec.originToken` from `_spec.depositor` and emit
    /// the L2->L1 commit log so the L1 linker can prove participation in the flow. Caller
    /// must equal `_spec.depositor`. One commit per (flowId, specHash). State transitions
    /// `Unset -> Committed`.
    function commitSend(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Mark each `_specHashes[i]` as `Executable`. Callable only by the aliased L1
    /// linker. Idempotent within a single call but cannot un-authorize. Valid prior states:
    /// `Unset` (destination, never saw a commit) or `Committed` (source, post-commit).
    function authorizeFromL1(bytes32 _flowId, bytes32[] calldata _specHashes) external;

    /// @notice Mark each `_specHashes[i]` as `Revertable`. Callable only by the aliased L1
    /// linker. Valid prior state: `Committed` only — refund is meaningful only on source
    /// chains that locked something.
    function authorizeRefundFromL1(bytes32 _flowId, bytes32[] calldata _specHashes) external;

    /// @notice Settle one leg. Anyone may call with the full `SendSpec` body. The escrow
    /// recomputes the hash, asserts `state == Executable`, then branches on
    /// `block.chainid`: source side performs the burn via AR/NTV, destination side
    /// performs the mint via AR/NTV. State transitions `Executable -> Executed`.
    function execute(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Refund the locked tokens to `_spec.depositor`. Anyone may call with the
    /// full `SendSpec` body; the escrow recomputes the hash, asserts `state == Revertable`,
    /// then `safeTransfer`s the locked amount back. State transitions
    /// `Revertable -> Reverted`.
    function claimRefund(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice The L1 linker address this escrow trusts (hardcoded constant).
    function L1_LINKER() external view returns (address);

    /// @notice Current per-`(flowId, specHash)` state.
    function bundleState(bytes32 _flowId, bytes32 _specHash) external view returns (SpecState);
}
