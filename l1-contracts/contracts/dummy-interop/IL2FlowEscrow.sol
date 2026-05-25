// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SendSpec} from "./IDummyFlow.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain custodian for the dummy flow stack. Users `commitSend` to lock tokens
/// and publish their outbound `SendSpec` as an L2→L1 commit log; the L1 linker collects
/// commit logs, finalizes the flow, and dispatches `executeFromL1` (or `refundFromL1`) via
/// `Bridgehub.requestL2TransactionDirect`. The escrow trusts the aliased L1 linker as the
/// sole authority for finality decisions — there is no destination-side proof verification.
interface IL2FlowEscrow {
    event FlowCommitted(bytes32 indexed flowId, address indexed depositor, SendSpec sendSpec);
    event FlowExecuted(bytes32 indexed flowId, uint256 inboundCount);
    event FlowRefunded(bytes32 indexed flowId, address indexed depositor);
    event InboundDelivered(
        bytes32 indexed flowId,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        bool followupInvoked
    );

    /// @notice Lock `_spec.amount` of `_spec.token` from `msg.sender` and emit the chain's
    /// L2→L1 commit log so the L1 linker can prove participation in the flow. The depositor
    /// is recorded for the refund path. One commit per flow id, per chain.
    function commitSend(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Settle the inbound side of the flow on this chain: mint each spec's `token`
    /// to its `recipient`, then invoke the followup call (if any). Callable only by the
    /// aliased L1 linker.
    /// @dev Idempotent guard via `settled[_flowId]`. If this chain also called `commitSend`,
    /// the lock is released to L1 (burned by transferring to address(0) for `DummyToken`),
    /// matching the burn-and-mint semantics of a real bridge.
    function executeFromL1(bytes32 _flowId, SendSpec[] calldata _inboundSpecs) external;

    /// @notice Return the locked tokens to the original depositor. Callable only by the
    /// aliased L1 linker after the flow has been reverted on L1 (e.g., past deadline with no
    /// finality). No-op for receive-only chains (which never locked anything).
    function refundFromL1(bytes32 _flowId) external;
}
