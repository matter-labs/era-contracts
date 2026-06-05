// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {FlowLeg, PartState, ImtInclusionProof, ImtNonInclusionProof} from "./IAtomicInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain escrow for the L1-free atomic interop flow.
///
/// Lifecycle (no L1 coordinator anywhere):
///   1. `commitPart` — the leg's payer locks tokens on this chain and a commit leaf is appended to
///      the chain's interop IMT. When the batch settles, the operator exposes the IMT root on L1.
///   2. `finalize`   — once a caller can prove (against an imported global interop-IMT root) that
///      *every* leg of the flow was committed before the deadline, this chain releases its leg's
///      locked tokens to the payee. Permissionless.
///   3. `refund`     — if instead a caller can prove that some leg is absent across the deadline
///      boundary, the locked tokens go back to the payer. Permissionless.
///
/// `flowId` is computed exactly as the off-chain coordinator does:
/// `keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`, where each `specHash` is
/// `keccak256(abi.encode(leg))`. Both arrays must be strictly ascending (sorted + deduplicated).
///
/// Deployed in L2 userspace (CREATE2), so it has no constructor — wiring is done in `initialize`.
interface IAtomicFlowEscrow {
    event PartCommitted(bytes32 indexed flowId, bytes32 indexed specHash, address indexed payer, uint256 leafIndex);
    event PartFinalized(bytes32 indexed flowId, bytes32 indexed specHash, address indexed payee, uint256 amount);
    event PartRefunded(bytes32 indexed flowId, bytes32 indexed specHash, address indexed payer, uint256 amount);

    /// @notice Lock `_leg.amount` of `_leg.token` from `_leg.payer` and insert the leg's commit
    /// value into the chain's indexed interop IMT. Caller must be `_leg.payer`; `_leg.chainId` must
    /// be this chain. State `Unset -> Committed`.
    /// @param _lowNullifierIndex The low-nullifier slot for the commit value in the current IMT,
    /// as computed by the IMT engine off-chain. (If the tree changed since, the insert reverts and
    /// the caller retries with a refreshed index.)
    function commitPart(bytes32 _flowId, FlowLeg calldata _leg, uint256 _lowNullifierIndex) external;

    /// @notice Finalize this chain's leg(s) of a flow whose every leg is proven committed in time.
    /// @param _flowId The flow identifier.
    /// @param _legs All legs of the flow, sorted ascending by `specHash`.
    /// @param _chainIds The flow's participant chain ids, strictly ascending.
    /// @param _deadline The flow deadline (compared against imported L1 timestamps).
    /// @param _proofs Inclusion proofs aligned 1:1 with `_legs`.
    function finalize(
        bytes32 _flowId,
        FlowLeg[] calldata _legs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        ImtInclusionProof[] calldata _proofs
    ) external;

    /// @notice Refund this chain's committed leg(s) of a flow that can no longer finalize, proven by
    /// a non-inclusion proof for one leg across the deadline boundary.
    /// @param _flowId The flow identifier.
    /// @param _legs All legs of the flow, sorted ascending by `specHash`.
    /// @param _chainIds The flow's participant chain ids, strictly ascending.
    /// @param _deadline The flow deadline.
    /// @param _missingLegIndex Index into `_legs` of the leg proven absent.
    /// @param _proof Non-inclusion proof for `_legs[_missingLegIndex]`.
    function refund(
        bytes32 _flowId,
        FlowLeg[] calldata _legs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        uint256 _missingLegIndex,
        ImtNonInclusionProof calldata _proof
    ) external;

    /// @notice Current state of a `(flowId, specHash)` leg on this chain.
    function partState(bytes32 _flowId, bytes32 _specHash) external view returns (PartState);

    /// @notice The interop commitment tree this escrow appends to.
    function commitmentTree() external view returns (address);

    /// @notice The global-root importer this escrow verifies proofs against.
    function importer() external view returns (address);
}
