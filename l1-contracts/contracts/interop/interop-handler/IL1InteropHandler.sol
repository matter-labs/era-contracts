// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev Transient storage slot for storing the settlement layer chain ID during proof verification.
/// @dev This slot is used to temporarily store which settlement layer is processing the current proof,
/// @dev and is cleared at the end of each transaction.
uint256 constant TRANSIENT_SETTLEMENT_LAYER_SLOT = uint256(keccak256("TRANSIENT_SETTLEMENT_LAYER_SLOT")) - 1;

/// @title L1 Interop Handler interface (L1-specific surface)
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 interop handler executes L2 -> L1 withdrawal bundles via the shared `IInteropHandler.executeBundle`
/// interface. This interface only exposes the L1-specific additions on top of that: the transient settlement-layer
/// slot it owns (recorded while proving inclusion, and consumed by `L1AssetTracker`), plus the nullifier-gated setter
/// the failed-deposit recovery flow uses to record the same slot.
interface IL1InteropHandler {
    event TransientSettlementLayerSet(uint256 indexed settlementLayerChainId);

    /// @notice The L1 nullifier that is allowed to record the transient settlement layer for its recovery flow.
    function l1Nullifier() external view returns (address);

    /// @notice Records the transient settlement layer for the current transaction.
    /// @dev Restricted to the L1 nullifier, which uses it while confirming failed-deposit recovery. The withdrawal
    /// finalization path (`executeBundle`) records the value itself while proving bundle inclusion.
    /// @param _settlementLayerChainId The chain ID of the settlement layer that processed the proof.
    /// @param _l2BatchNumber The L2 batch number the proof was included in.
    function setTransientSettlementLayer(uint256 _settlementLayerChainId, uint256 _l2BatchNumber) external;

    /// @notice Retrieves the currently stored transient settlement layer chain ID and batch number.
    /// @dev The transient settlement layer is cleared at the end of each transaction.
    /// @dev Note, that it is a hard assumption that must be enforced by all the users of this function:
    /// Any operation that reads this value must be preceded by a successful invocation of the L1 interop handler
    /// (directly via `executeBundle`, or via the L1 nullifier recovery flow) that has set this value. Otherwise, it is
    /// possible that the same value is reused multiple times.
    /// @return The chain ID of the settlement layer that processed the current proof, or 0 if none is set.
    function getTransientSettlementLayer() external view returns (uint256, uint256);
}
