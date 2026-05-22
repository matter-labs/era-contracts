// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

error FlowAlreadyExists(bytes32 flowId);
error FlowDeadlineInPast(uint64 deadline);
error FlowMustHaveLocks();
error LockAmountZero();
error NativeValueMismatch(uint256 expected, uint256 actual);
error FlowNotInitiated(bytes32 flowId);
error FlowExpired(bytes32 flowId);
error FlowNotExpired(bytes32 flowId, uint64 deadline);
error NotIncludedInIMT(bytes32 flowId, bytes32 root);
error IncludedInIMT(bytes32 flowId, bytes32 root);
error NativeTransferFailed(address to, uint256 amount);
error EmptyBundleHash();
error BundleAlreadyAttached(bytes32 bundleHash, bytes32 existingFlowId);
error FlowNotFinalized(bytes32 flowId);
error UnexpectedSimulatedBundle(bytes32 verifyHash);
error FlowNotSimulated(bytes32 flowId);
error FlowAlreadySimulated(bytes32 flowId);
error SelfChainInPeerLogs();
error PeerLogSenderMismatch(address actual);
error PeerLogNotIncluded(uint256 chainId);
error PeerLogTagMismatch(bytes4 actual);
error PeerLogFlowIdMismatch(bytes32 actual);
error DestChainNotInParticipatingSet(uint256 destChainId);
error TooManyExpectedBundles(uint256 provided);

/// @notice Sentinel error: `runPlan` always reverts with this on success so the EVM rolls
/// back every state change made during plan execution. `simulate` catches it. The error's
/// parameters carry the auto-recorded bundle data out of the reverting frame — transient
/// storage updates inside the revert tree are themselves rolled back per EIP-1153, so the
/// only path back to `simulate`'s outer frame is via the revert payload.
error SimulationCompleted(bytes32[] hashes, uint256[] destChainIds, bytes[] bundleBytes);
