// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Implemented by any contract that can be the target (`InteropCall.to`) of an atomic-interop
/// bundle call and knows how to reverse that call when the flow times out. The {AtomicFlowManager}
/// drives the timeout refund generically through this interface — it does not need to understand any
/// particular target's call/encoding format.
interface IAtomicRecoverable {
    /// @notice Reverse a single atomic-bundle call whose flow timed out, re-crediting the original
    /// depositor. Called by the {AtomicFlowManager} once per bundle call during `claimRefund`.
    /// @dev Implementations MUST restrict this to the canonical {AtomicFlowManager} and MUST return
    /// `false` (rather than revert) for call data they do not recognise as recoverable, so a bundle may
    /// mix recoverable and non-recoverable calls. `_callData` is the original `InteropCall.data`.
    /// @dev Provenance (MUST). A fund-moving call is only backed by a real source burn if it was produced
    /// by the target's own send-side (indirect-call/burn) path, which pins `InteropCall.from` to a value
    /// the target controls. An implementation that releases or mints funds MUST verify `_sender`
    /// identifies that path and MUST return `false` otherwise — a direct or forged call carries an
    /// unrelated `from` and has no burn to reverse, so recovering it would mint/release funds for a burn
    /// that never happened.
    /// @param _destChainId The bundle's destination chain id (the chain the original call targeted).
    /// @param _sender The original `InteropCall.from` — the source-side originator of the call.
    /// @param _callData The original call's calldata.
    /// @return recovered True if this target recognised and reversed the call.
    function recoverAtomicCall(
        uint256 _destChainId,
        address _sender,
        bytes calldata _callData
    ) external returns (bool recovered);
}
