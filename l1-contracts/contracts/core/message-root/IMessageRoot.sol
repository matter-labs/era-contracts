// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMessageVerification} from "../../common/interfaces/IMessageVerification.sol";
import {ProofData, StoredInteropRoot} from "../../common/Messaging.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// The single shared tree consists of the roots of chain trees as its leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// The value that is saved in the v31UpgradeChainBatchNumber mapping for all deployed chains until the chain upgrades to v31.
uint256 constant V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE = uint256(
    keccak256(abi.encodePacked("V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE"))
);

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IMessageRootBase is IMessageVerification {
    /// @notice Emitted when a new chain is added to the MessageRoot.
    /// @param chainId The ID of the chain that is being added to the MessageRoot.
    /// @param chainIndex The index of the chain that is being added. Note, that chain where
    /// the MessageRoot contract was deployed has chainIndex of 0, and this event is being emitted for it.
    event AddedChain(uint256 indexed chainId, uint256 indexed chainIndex);

    /// @notice Emitted when a new chain batch root is appended to the chainTree.
    /// @param chainId The ID of the chain whose chain batch root is being added to the chainTree.
    /// @param batchNumber The number of the batch to which chain batch root belongs.
    /// @param chainBatchRoot The value of chain batch root which is being added.
    /// @param l1Timestamp The settlement-layer block timestamp at which the batch root was aggregated,
    /// bound into the batch leaf so it is provable via the aggregated-root inclusion proof.
    event AppendedChainBatchRoot(
        uint256 indexed chainId,
        uint256 indexed batchNumber,
        bytes32 chainBatchRoot,
        uint256 l1Timestamp
    );

    /// @notice Emitted when a new chainTree root is produced and its corresponding leaf in sharedTree is updated.
    /// @param chainId The ID of the chain whose chainTree root is being updated.
    /// @param chainRoot The updated Merkle root of the chainTree after appending the latest batch root.
    /// @param chainIdLeafHash The Merkle leaf value computed from `chainRoot` and the chain's ID, used to update the shared tree.
    event NewChainRoot(uint256 indexed chainId, bytes32 chainRoot, bytes32 chainIdLeafHash);

    /// @notice Emitted whenever the sharedTree is updated, and the new InteropRoot (root of the sharedTree) is generated.
    /// @param chainId The ID of the chain where the sharedTree was updated (the settlement layer's own chain id).
    /// @param blockNumber The block number of the block in which the sharedTree was updated.
    /// @param logId The per-block ID of the emission: all NewInteropRoot events within one block share
    /// the same logId (it increments at most once per block), so off-chain consumers can group them.
    /// @param timestamp The block timestamp at which the root was created — the third element of the
    /// `(blockNumber, root, timestamp)` tuple chains import, so the event reports the full interop
    /// root info.
    /// @param sides The "sides" of the interop root. In this release, which uses proof-based interop, the
    /// sides are an array of length one holding only the interop root itself. More on that in the
    /// `L2InteropRootStorage` contract.
    event NewInteropRoot(
        uint256 indexed chainId,
        uint256 indexed blockNumber,
        uint256 indexed logId,
        uint256 timestamp,
        bytes32[] sides
    );

    function BRIDGE_HUB() external view returns (address);

    function addNewChain(uint256 _chainId, uint256 _startingBatchNumber) external;

    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;

    function addChainBatchRootV32(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;

    function seedGenesisRoot(uint256 _chainId) external;

    function chainBatchRoots(uint256 _chainId, uint256 _batchNumber) external view returns (bytes32);

    /// @notice The global message root written at `_blockNumber` together with the block timestamp at
    /// which it was written — the `(blockNumber, root, timestamp)` tuple that chains import; the
    /// imported tuple is double checked against this record during batch execution.
    function historicalRoot(uint256 _blockNumber) external view returns (StoredInteropRoot memory);

    /// @dev Used to parse the merkle proof data, this function calls a library function.
    function getProofData(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external pure returns (ProofData memory);

    function setMigratingChainBatchNumber(uint256 _chainId, uint256 _batchNumber) external;

    function currentChainBatchNumber(uint256 _chainId) external view returns (uint256);

    /// @notice The number of batch leaves in a chain's tree on this settlement layer (non-zero means
    /// the chain has at least one batch inside the aggregated shared root).
    function chainTreeLeafCount(uint256 _chainId) external view returns (uint256);

    function getMerklePathForChain(uint256 _chainId) external view returns (bytes32[] memory);
}
