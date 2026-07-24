// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {StoredInteropRoot} from "../common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L2 InteropRootStorage contract,
 * responsible for storing the message roots of other chains on the L2.
 */
interface IL2InteropRootStorage {
    event InteropRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, uint256 timestamp, bytes32[] sides);

    /// @notice Returns the imported message root and its creation timestamp (the
    /// `(blockOrBatchNumber, root, timestamp)` tuple) for a chain ID and block or batch number.
    /// @dev Every import entry point carries the creation timestamp, so stored roots always hold the
    /// full tuple; a zero timestamp only ever means "nothing imported at this key".
    function interopRoots(uint256 chainId, uint256 blockOrBatchNumber) external view returns (StoredInteropRoot memory);
}
