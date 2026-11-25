// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteropRoot, StoredInteropRoot} from "../common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L2 InteropRootStorage contract,
 * responsible for storing the message roots of other chains on the L2.
 */
interface IL2InteropRootStorage {
    event InteropRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, uint256 timestamp, bytes32[] sides);

    /// @notice `writer` added an interop root of `chainId`. See {protocol-docs/interop.md#interop-root-writers}.
    event InteropRootAddedByWriter(
        uint256 indexed chainId,
        uint256 indexed blockNumber,
        uint256 timestamp,
        bytes32[] sides,
        address indexed writer
    );

    /// @notice `writer` may now add the interop roots of `sourceChainId`; zero removes the writer.
    event InteropRootWriterSet(uint256 indexed sourceChainId, address indexed writer);

    /// @notice Returns the imported message root and its creation timestamp (the
    /// `(blockOrBatchNumber, root, timestamp)` tuple) for a chain ID and block or batch number.
    /// @dev A zero timestamp only ever means "nothing imported at this key"; see
    /// {protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check} for
    /// the import invariants.
    function interopRoots(uint256 chainId, uint256 blockOrBatchNumber) external view returns (StoredInteropRoot memory);

    /// @notice Returns the maximum creation timestamp over all roots imported for `chainId` (zero if
    /// none was imported yet). Monotonically non-decreasing: once a root created at time `T` is
    /// imported, the returned value is `>= T` forever, so it is an authenticated lower bound on the
    /// referenced chain's clock as observed by this chain.
    function latestInteropRootTimestamp(uint256 chainId) external view returns (uint256);

    /// @notice Returns the address that may add the interop roots of `sourceChainId`, or zero if there is none.
    /// See {protocol-docs/interop.md#interop-root-writers}.
    function interopRootWriter(uint256 sourceChainId) external view returns (address);

    /// @notice Sets or, with zero, removes the writer of `_sourceChainId`'s interop roots. Called by a service
    /// transaction from the L1 `ChainRegistrationSender`. See {protocol-docs/interop.md#interop-root-writers}.
    /// @param _sourceChainId The chain whose roots the writer adds. Must not be this chain.
    /// @param _writer The writer, any address (an operator key or a contract such as a light client).
    function setInteropRootWriter(uint256 _sourceChainId, address _writer) external;

    /// @notice Adds an interop root of `_interopRoot.chainId`, under the same invariants as a bootloader import.
    /// Callable by that chain's writer while the chain feature `INTEROP_ROOT_WRITERS_FEATURE` is enabled. The root
    /// does not enter the batch's `dependencyRootsRollingHash`, so the settlement layer does not check it: it is
    /// exactly as trustworthy as the writer. See {protocol-docs/interop.md#interop-root-writers}.
    /// @param _interopRoot The root; `sides` must hold exactly the root.
    function addInteropRootFromWriter(InteropRoot calldata _interopRoot) external;
}
