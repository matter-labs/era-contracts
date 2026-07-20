// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev Minimum byte length of an ERC-7930 v1 address:
/// version (2) + chainType (2) + chainReferenceLength (1) + addressLength (1).
uint256 constant ERC7930_V1_MIN_LENGTH = 0x06;

/// @dev The maximum number of legs an atomic flow may declare in its `flowId` preimage
/// (see {AtomicFlowPreimage}). A bound is load-bearing: each leg's registration check at send time is
/// cheap, but finalizing the flow on a destination (`AtomicFlowManager.requireFlowFinalized`) verifies
/// one IMT inclusion proof — with its own multi-hop settlement proof — per leg, all inside a single
/// transaction. Without a cap, a flow could pass every source-side send yet exceed the transaction gas
/// or calldata limits on every finalization attempt; once all legs are committed, the absence-based
/// timeout refund is impossible too, stranding the burned funds. The value is conservative: far above
/// any practical flow size, far below what a single transaction can prove.
uint256 constant MAX_ATOMIC_FLOW_LEGS = 16;
