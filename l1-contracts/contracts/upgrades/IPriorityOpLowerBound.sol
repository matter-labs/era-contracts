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
    /// tracked — so every priority op below the recorded bound provably includes the draft-v31
    /// backfill service transaction.
    /// @param _chain The chain's DiamondProxy address.
    function lowerBoundPriorityOp(address _chain) external;

    /// @notice The recorded priority-op count for a chain; zero means not recorded yet.
    function lowerBound(address _chain) external view returns (uint256);
}
