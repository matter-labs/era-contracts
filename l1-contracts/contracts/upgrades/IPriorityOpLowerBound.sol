// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title IPriorityOpLowerBound
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IPriorityOpLowerBound {
    /// @notice Emitted when a chain's lower bound is recorded.
    event LowerBoundRecorded(address indexed chain, uint256 lowerBound);

    /// @notice Records `_chain`'s current total priority-op count as its lower bound, once.
    /// @dev Callable by anyone, but only while the chain reports its base-token total supply as
    /// tracked — so every priority op below the recorded bound provably includes the v31
    /// backfill service transaction (or there was none to include: a chain created on v31 records
    /// a legitimate zero).
    /// @param _chain The chain's DiamondProxy address.
    function lowerBoundPriorityOp(address _chain) external;

    /// @notice The recorded priority-op count for a chain; meaningful only once `recorded`.
    function lowerBound(address _chain) external view returns (uint256);

    /// @notice Whether a lower bound was recorded for the chain.
    function recorded(address _chain) external view returns (bool);
}
