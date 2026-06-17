// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SendSpec, SpecState, ImtInclusionProof, ImtNonInclusionProof} from "./IAtomicInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain escrow for the L1-free atomic interop flow. Asset mechanics route through the L2
/// asset router + native token vault; cross-chain authorization is gated by **IMT proofs** against the
/// interop root the verifying chain imports for a settled source batch (see {AtomicInteropProof}) —
/// no L1 coordinator.
///
///   1. `commitSend` — the source depositor's tokens are pulled and immediately **burned** (origin-
///      native: locked) through AR/NTV, and the leg's commit value is inserted into this chain's
///      indexed interop IMT. The source happy path is terminal here (`Committed`); there is no source
///      `execute`.
///   2. `authorize` — once a caller proves *every* spec of the flow was committed before the deadline,
///      this chain's **destination** legs become `Executable`. Permissionless.
///   3. `execute` — mints the destination leg to its recipient via AR/NTV. Destination-only.
///   4. `authorizeRefund` / `claimRefund` — the timeout path: prove (O(log n) non-inclusion) that a leg
///      can no longer be committed in time, then **recover** the burned source funds to the depositor.
///
/// `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`,
/// `specHash = keccak256(abi.encode(spec))`; both arrays strictly ascending.
///
/// Deployed in L2 userspace (CREATE2), so it has no constructor — wiring is done in `initialize`.
interface IAtomicFlowEscrow {
    event FlowCommitted(bytes32 indexed flowId, bytes32 indexed specHash, address indexed depositor, uint256 leafIndex);
    event FlowAuthorized(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowExecuted(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowRefundAuthorized(bytes32 indexed flowId, bytes32 indexed specHash);
    event FlowRefunded(bytes32 indexed flowId, bytes32 indexed specHash, address indexed depositor);

    /// @notice Pull `_spec.amount` of `_spec.originToken` from `_spec.depositor`, burn/lock it through
    /// AR/NTV, and insert the spec's commit value into the chain's indexed interop IMT. Caller must be
    /// `_spec.depositor`; `_spec.originChainId` must be this chain. State `Unset -> Committed` (terminal
    /// on the happy path).
    /// @param _lowNullifierIndex The low-nullifier slot for the commit value (from the IMT engine).
    function commitSend(bytes32 _flowId, SendSpec calldata _spec, uint256 _lowNullifierIndex) external;

    /// @notice Mark this chain's destination legs `Executable`, once every spec of the flow is proven
    /// committed in time. Permissionless. Destination legs transition `Unset -> Executable`; source
    /// legs are unaffected (terminal at `Committed`).
    /// @param _specs All specs of the flow, sorted ascending by `specHash`.
    /// @param _chainIds The flow's participant chain ids, strictly ascending.
    /// @param _deadline The flow deadline (compared against the authenticated root snapshot timestamp).
    /// @param _proofs Inclusion proofs for each spec NOT originating on this chain, in spec order.
    function authorize(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        ImtInclusionProof[] calldata _proofs
    ) external;

    /// @notice Settle a destination leg: mint to its recipient via AR/NTV. Anyone may call with the
    /// full `SendSpec`. Requires `Executable` and `destChainId == block.chainid`. State
    /// `Executable -> Executed`.
    function execute(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Mark this chain's source legs `Revertable` for a flow that can no longer finalize, proven
    /// by a non-inclusion proof for one spec past the deadline. Permissionless.
    /// @param _missingSpecIndex Index into `_specs` of the spec proven absent.
    function authorizeRefund(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        uint256 _missingSpecIndex,
        ImtNonInclusionProof calldata _proof
    ) external;

    /// @notice Recover the burned/locked source funds to `_spec.depositor` via AR/NTV. Requires
    /// `Revertable`. State `Revertable -> Reverted`.
    function claimRefund(bytes32 _flowId, SendSpec calldata _spec) external;

    /// @notice Current state of a `(flowId, specHash)` on this chain.
    function specState(bytes32 _flowId, bytes32 _specHash) external view returns (SpecState);

    /// @notice The interop commitment tree this escrow inserts into.
    function commitmentTree() external view returns (address);

    /// @notice The L2 asset router used for burns/mints/recovery.
    function assetRouter() external view returns (address);

    /// @notice The L2 native token vault used for source-side allowances.
    function nativeTokenVault() external view returns (address);
}
