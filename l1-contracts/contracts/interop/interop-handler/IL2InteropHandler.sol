// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {AtomicFinalityProof} from "../../atomic-interop/IAtomicInterop.sol";
import {IInteropHandlerBase} from "./IInteropHandlerBase.sol";

/// @notice L2 interop handler surface: the proof-agnostic {IInteropHandlerBase} plus the atomic-proof-typed
/// execute/verify entry points. L2->L2 interop is proven via the {AtomicFlowManager}'s IMT
/// (`AtomicFinalityProof`), not via L1 message inclusion.
/// @dev Kept separate from the concrete {L2InteropHandler} so that {L2ContractInterfaces} can type the
/// `L2_INTEROP_HANDLER` built-in against an interface instead of importing the implementation (which itself
/// imports {L2ContractInterfaces}, i.e. it breaks that import cycle).
interface IL2InteropHandler is IInteropHandlerBase {
    /// @notice Emitted when an expirable flow's leg expires instead of executing.
    event BundleExpired(bytes32 indexed bundleHash);

    /// @notice Executes a full atomic interop bundle, gated by per-leg IMT inclusion proofs.
    /// @dev Named distinctly from {L1InteropHandler.executeBundle} (which takes a `MessageInclusionProof`) so
    /// the atomic vs L1-message-inclusion path is obvious at the call site.
    /// @param _bundle ABI-encoded InteropBundle to execute.
    /// @param _finality The flow definition (`flowId`, legs, deadline) + one IMT inclusion proof per leg.
    function executeAtomicBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) external;

    /// @notice Verifies receipt of an atomic bundle without executing its calls (enables verify->unbundle).
    /// @dev Named distinctly from {L1InteropHandler.verifyBundle} (which takes a `MessageInclusionProof`),
    /// matching {executeAtomicBundle}.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _finality The flow definition + one IMT inclusion proof per leg.
    function verifyAtomicBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) external;

    /// @notice Expires an expirable flow's leg so it never executes and its source can refund it. Permissionless.
    /// See {protocol-docs/atomicity/expiry.md#expiry-on-the-destination}.
    /// @param _bundle ABI-encoded InteropBundle of the leg.
    /// @param _finality The flow definition + its leg's inclusion proof.
    /// @param _lowNullifierIndex The low-nullifier slot for the leg's expiry value in this chain's IMT.
    function expireAtomicBundle(
        bytes calldata _bundle,
        AtomicFinalityProof calldata _finality,
        uint256 _lowNullifierIndex
    ) external;
}
