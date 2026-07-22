// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Implemented by a local contract that produces atomic-interop bundle calls (`InteropCall.from`,
/// e.g. the asset router's burn path) and knows how to reverse them when the flow times out. The
/// {AtomicFlowManager} drives the timeout refund generically through this interface — it does not need
/// to understand any particular sender's call/encoding format.
interface IAtomicRecoverable {
    /// @notice Reverse a single atomic-bundle call whose flow timed out, re-crediting the original
    /// depositor. Called by the {AtomicFlowManager} once per bundle call during `claimRefund`.
    /// @dev Implementations MUST restrict this to the canonical {AtomicFlowManager} and MUST return
    /// `false` (rather than revert) for call data they do not recognise as recoverable, so a bundle may
    /// mix recoverable and non-recoverable calls. `_callData` is the original `InteropCall.data`.
    /// @param _destChainId The bundle's destination chain id (the chain the original call targeted).
    /// @param _callData The original call's calldata.
    /// @return recovered True if this sender recognised and reversed the call.
    function recoverAtomicCall(uint256 _destChainId, bytes calldata _callData) external returns (bool recovered);
}
