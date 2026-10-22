// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reverts with an already encoded custom error, so checks that return their failure can be shared by paths
/// that revert and paths that skip.
/// @param _reason The ABI-encoded error.
function revertWith(bytes memory _reason) pure {
    assembly {
        revert(add(_reason, 0x20), mload(_reason))
    }
}
