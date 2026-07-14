// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;
/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L2 InteropRootStorage contract,
 * responsible for storing the message roots of other chains on the L2.
 */
interface IL2InteropRootStorage {
    event InteropRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, uint256 timestamp, bytes32[] sides);

    /// @notice Mapping of chain ID to block or batch number to the imported message root and its
    /// creation timestamp (the `(blockOrBatchNumber, root, timestamp)` tuple).
    /// @dev The timestamp is zero for roots imported through the legacy (timestamp-less) path; such
    /// roots cannot be used for time-sensitive proofs (e.g. the atomic-interop timeout protocol).
    function interopRoots(
        uint256 chainId,
        uint256 blockOrBatchNumber
    ) external view returns (bytes32 root, uint256 timestamp);
}
