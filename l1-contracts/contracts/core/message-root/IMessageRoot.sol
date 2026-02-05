// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMessageVerification} from "../../common/interfaces/IMessageVerification.sol";
import {ProofData} from "../../common/Messaging.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// The single shared tree consists of the roots of chain trees as its leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// The value that is saved in the v31UpgradeChainBatchNumber mapping for all deployed chains until the chain upgrades to v31.
uint256 constant V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY = uint256(
    keccak256(abi.encodePacked("V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY"))
);

// The value that is saved in the v31UpgradeChainBatchNumber mapping for all deployed chains until the chain upgrades to v31.
uint256 constant V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1 = uint256(
    keccak256(abi.encodePacked("V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1"))
);

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IMessageRoot is IMessageVerification {
    /// @notice Emitted when a new chain is added to the MessageRoot.
    /// @param chainId The ID of the chain that is being added to the MessageRoot.
    /// @param chainIndex The index of the chain that is being added. Note, that chain where
    /// the MessageRoot contract was deployed has chainIndex of 0, and this event is being emitted for it.
    event AddedChain(uint256 indexed chainId, uint256 indexed chainIndex);

    /// @notice Emitted when a new chain batch root is appended to the chainTree.
    /// @param chainId The ID of the chain whose chain batch root is being added to the chainTree.
    /// @param batchNumber The number of the batch to which chain batch root belongs.
    /// @param chainBatchRoot The value of chain batch root which is being added.
    event AppendedChainBatchRoot(uint256 indexed chainId, uint256 indexed batchNumber, bytes32 chainBatchRoot);

    /// @notice Emitted when a new chainTree root is produced and its corresponding leaf in sharedTree is updated.
    /// @param chainId The ID of the chain whose chainTree root is being updated.
    /// @param chainRoot The updated Merkle root of the chainTree after appending the latest batch root.
    /// @param chainIdLeafHash The Merkle leaf value computed from `chainRoot` and the chain’s ID, used to update the shared tree.
    event NewChainRoot(uint256 indexed chainId, bytes32 chainRoot, bytes32 chainIdLeafHash);

    /// @notice Emitted whenever the sharedTree is updated, and the new InteropRoot (root of the sharedTree) is generated.
    /// @param chainId The ID of the chain where the sharedTree was updated.
    /// @param blockNumber The block number of the block in which the sharedTree was updated.
    /// @param logId The ID of the log emitted when a new InteropRoot. In this release always equal to 0.
    /// @param sides The "sides" of the interop root. In this release which uses proof-based interop the sides is an array
    /// of length one, which only include the interop root itself. More on that in `L2InteropRootStorage` contract.
    event NewInteropRoot(uint256 indexed chainId, uint256 indexed blockNumber, uint256 indexed logId, bytes32[] sides);

    function BRIDGE_HUB() external view returns (address);

    function ERA_GATEWAY_CHAIN_ID() external view returns (uint256);

    function addNewChain(uint256 _chainId, uint256 _startingBatchNumber) external;

    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;

    function chainBatchRoots(uint256 _chainId, uint256 _batchNumber) external view returns (bytes32);

    function historicalRoot(uint256 _blockNumber) external view returns (bytes32);

    /// @dev Used to parse the merkle proof data, this function calls a library function.
    function getProofData(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external pure returns (ProofData memory);

    function setMigratingChainBatchRoot(uint256 _chainId, uint256 _batchNumber) external;

    function currentChainBatchNumber(uint256 _chainId) external view returns (uint256);

    function getMerklePathForChain(uint256 _chainId) external view returns (bytes32[] memory);
}
