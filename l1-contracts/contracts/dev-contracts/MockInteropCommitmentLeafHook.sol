// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockInteropCommitmentLeafHook
/// @notice Mock for the ZKsync OS INTEROP_COMMITMENT_LEAF_HOOK (address 0x7004).
/// @dev In production this hook records the inserted value as an L2->L1 log in the ZKsync OS state.
/// Here it just captures the raw calldata it was called with, so tests can assert what the
/// L2InteropCommitmentTree reported and how many times.
contract MockInteropCommitmentLeafHook {
    /// @notice Raw calldata of the most recent hook call.
    bytes public lastCalldata;
    /// @notice Number of times the hook has been called.
    uint256 public callCount;

    fallback() external payable {
        lastCalldata = msg.data;
        ++callCount;
    }

    receive() external payable {}
}
