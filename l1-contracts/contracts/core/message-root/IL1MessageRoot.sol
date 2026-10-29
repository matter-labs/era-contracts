// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {StoredInteropRoot} from "../../common/Messaging.sol";

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    /// @notice Governance enabled interop for the chain.
    event InteropEnabled(uint256 indexed chainId);

    /// @notice An L1 block hash was recorded for L1SLOAD anchors.
    event L1BlockHashRecorded(uint256 indexed blockNumber, bytes32 blockHash, uint256 timestamp);

    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);

    /// @notice Enables interop for a chain. One-way: there is no way to disable it. Callable by the
    /// Bridgehub owner, once the chain is no longer pending its balance backfill.
    /// See {protocol-docs/interop-gating.md#enabling-interop}.
    /// @param _chainId The chain to enable interop for.
    /// @param _requireSecondProofSystem Whether the chain must permanently require its second proof system and be
    /// in multi-proof mode.
    function enableInterop(uint256 _chainId, bool _requireSecondProofSystem) external;

    /// @notice Returns whether governance enabled interop for the chain; false for unknown chains.
    /// See {protocol-docs/interop-gating.md}.
    /// @param _chainId The chain to query.
    function isInteropEnabled(uint256 _chainId) external view returns (bool);

    /// @notice Records the previous L1 block's hash, which chains import as their L1SLOAD anchor. Permissionless.
    /// See {protocol-docs/l1sload.md#anchors}.
    /// @return blockNumber The recorded block, `block.number - 1`.
    /// @return blockHash Its hash.
    function recordL1BlockHash() external returns (uint256 blockNumber, bytes32 blockHash);

    /// @notice Returns the recorded hash of an L1 block and the time it was recorded at; zero if it was not recorded.
    /// @param _blockNumber The L1 block number.
    function recordedL1BlockHash(uint256 _blockNumber) external view returns (StoredInteropRoot memory);
}
