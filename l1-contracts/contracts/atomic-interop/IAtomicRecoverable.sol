// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Implemented by a local contract that produces atomic-interop bundle calls (`InteropCall.from`,
/// e.g. the asset router's burn path) and knows how to reverse them when the flow times out.
/// See {protocol-docs/atomicity/recovery.md} (timeout / refund). Note that the manager's recovery
/// dispatch is currently pinned to the L2 asset router — no other implementer is invoked (see
/// {protocol-docs/atomicity/security.md#known-issues-and-accepted-limitations}); the requirements
/// below bind the asset router today and any sender a future generic dispatch adds.
interface IAtomicRecoverable {
    /// @notice Reverses a single atomic-bundle call whose flow timed out, re-crediting the original depositor.
    /// @dev Implementations MUST restrict this to the canonical {AtomicFlowManager} and MUST return
    /// `false` (rather than revert) for call data they do not recognise as recoverable, so a bundle may
    /// mix recoverable and non-recoverable calls.
    /// @param _destChainId The original call's destination chain id.
    /// @param _callData The original `InteropCall.data`.
    /// @return recovered True if this sender recognised and reversed the call.
    function recoverAtomicCall(uint256 _destChainId, bytes calldata _callData) external returns (bool recovered);
}
