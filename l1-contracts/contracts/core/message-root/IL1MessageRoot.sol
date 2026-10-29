// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMTLeaf} from "../../common/libraries/IndexedMerkleTree.sol";

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    /// @notice Governance enabled interop for the chain.
    event InteropEnabled(uint256 indexed chainId);

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

    /// @notice Emitted when an atomic-flow leg sourced on L1 is committed.
    /// @param batchNumber The batch of L1 (in L1's chain tree) the leg settles in.
    /// @param leafIndex The leg's index in L1's commitment tree.
    /// @param commitValue The leg's commit value.
    event L1LegCommitted(uint256 indexed batchNumber, uint256 leafIndex, uint256 commitValue);

    /// @notice Commits an atomic-flow leg sourced on L1 into L1's commitment tree and settles it at once, as a
    /// batch of L1 in L1's chain tree, so the next interop root carries it to every chain.
    /// @dev Only the L1 asset router (`L1AssetRouter.depositViaInterop`).
    /// @param _commitValue The leg's commit value (`AtomicInteropProof.commitValue`).
    /// @param _lowNullifierIndex A hint for the leaf preceding the value (see `IndexedMerkleTree.insert`).
    /// @return batchNumber The batch of L1 the leg settled in.
    function commitL1Leg(uint256 _commitValue, uint256 _lowNullifierIndex) external returns (uint256 batchNumber);

    /// @notice The current root of L1's commitment tree.
    function l1CommitmentTreeRoot() external view returns (bytes32);

    /// @notice The number of leaves in L1's commitment tree, the index-0 sentinel included (0 before the first leg).
    function l1CommitmentTreeLeafCount() external view returns (uint256);

    /// @notice A leaf of L1's commitment tree, for building inclusion and absence proofs.
    function l1CommitmentTreeLeafAt(uint256 _index) external view returns (IMTLeaf memory);

    /// @notice The Merkle path of a leaf of L1's commitment tree.
    function l1CommitmentTreeMerklePath(uint256 _index) external view returns (bytes32[] memory);
}
