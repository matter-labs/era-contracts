// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Lifecycle of a flow on the L1 linker. Tracked only on L1 — L2 escrows derive
/// their own state from the L1→L2 dispatch txs (`executeFromL1` / `refundFromL1`).
enum FlowState {
    None,
    Initiated,
    Finalized,
    Reverted
}

/// @notice Declarative description of one chain's outbound contribution to a flow.
/// `amount == 0` denotes a receive-only / no-outbound participant. `followupTo == address(0)`
/// denotes no atomic-on-arrival callback.
/// @dev The L2 escrow pulls `amount` of `token` from the depositor at `commitSend`; the L1
/// linker forwards this struct verbatim to `destChainId` via `executeFromL1`, where the
/// destination escrow mints `amount` of `recipient`'s local token and then optionally calls
/// `followupTo(followupData)` in the same tx.
struct SendSpec {
    uint256 destChainId;
    address recipient;
    address token;
    uint256 amount;
    address followupTo;
    bytes followupData;
}

/// @notice One participating chain in a flow. `escrow` is the chain-local `L2FlowEscrow`
/// instance the registrar has chosen — the L1 linker validates each commit log's sender
/// against this address and dispatches `executeFromL1` to it.
struct Participant {
    uint256 chainId;
    address escrow;
}

/// @dev Tag prepended to every L2→L1 commit log so the linker can recognize them. Versioned
/// so future commit-log schema changes can coexist without selector collisions.
bytes4 constant COMMIT_LOG_TAG = bytes4(keccak256("DummyFlow.commit.v1"));
