// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NonConsecutiveBatch, NotTheChain} from "../ZKIPLiteErrors.sol";
import {DynamicIncrementalMerkle} from "era/common/libraries/DynamicIncrementalMerkle.sol";
import {FullMerkle} from "era/common/libraries/FullMerkle.sol";
import {Merkle} from "era/common/libraries/Merkle.sol";
import {MessageHashing} from "era/common/libraries/MessageHashing.sol";
import {ChainBatchRootTree} from "era/common/libraries/ChainBatchRootTree.sol";
import {StoredInteropRoot} from "era/common/Messaging.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH, SHARED_ROOT_TREE_EMPTY_HASH} from "era/core/message-root/IMessageRoot.sol";

/// @notice The aggregation half of MessageRootBase's (_addNewChain, seedGenesisRoot,
/// _pushChainBatchRoot, historicalRoots) on the same libraries, so every root and path hashes exactly as
/// on L1. Access control is reduced to "a chain's registered contract pushes its own roots". It also keeps
/// each chain tree's leaves, to hand out the paths that are built off-chain in production.
contract MockMessageRoot {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    uint256 public chainCount;
    mapping(uint256 chainId => uint256 index) public chainIndex;
    mapping(uint256 chainId => address chain) public chainContract;
    FullMerkle.FullTree internal sharedTree;
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;
    mapping(uint256 chainId => bytes32[] leaves) internal chainLeaves;
    mapping(uint256 blockNumber => StoredInteropRoot root) internal historicalRoots;
    mapping(uint256 chainId => uint256 batchNumber) public currentChainBatchNumber;
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 root)) public chainBatchRoots;
    mapping(uint256 chainId => mapping(uint256 batchNumber => uint256 l1Timestamp)) public chainBatchRootTimestamp;


    constructor() {
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
        _addNewChain(block.chainid, address(0));
    }

    /// @notice Registers a fresh chain and seeds its genesis chain batch root as batch 0.
    function addChain(uint256 _chainId, address _chain) external {
        _addNewChain(_chainId, _chain);
        bytes32 genesis = ChainBatchRootTree.genesisChainBatchRoot();
        chainBatchRoots[_chainId][0] = genesis;
        _push(_chainId, 0, genesis);
    }

    function pushChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external {
        require(msg.sender == chainContract[_chainId], NotTheChain());
        require(_batchNumber == currentChainBatchNumber[_chainId] + 1, NonConsecutiveBatch());
        currentChainBatchNumber[_chainId] = _batchNumber;
        chainBatchRoots[_chainId][_batchNumber] = _chainBatchRoot;
        _push(_chainId, _batchNumber, _chainBatchRoot);
    }

    function historicalRoot(uint256 _blockNumber) external view returns (StoredInteropRoot memory) {
        return historicalRoots[_blockNumber];
    }

    function sharedRoot() external view returns (bytes32) {
        return sharedTree.root();
    }

    /// @notice Path of batch `_batchNumber`'s leaf in the chain's current batch tree.
    function chainTreePath(uint256 _chainId, uint256 _batchNumber) external view returns (bytes32[] memory path) {
        bytes32[] memory level = chainLeaves[_chainId];
        uint256 levels = chainTree[_chainId].height();
        path = new bytes32[](levels);
        bytes32 zero = CHAIN_TREE_EMPTY_ENTRY_HASH;
        uint256 index = _batchNumber;
        for (uint256 i = 0; i < levels; ++i) {
            uint256 sibling = index ^ 1;
            path[i] = sibling < level.length ? level[sibling] : zero;
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 k = 0; k < next.length; ++k) {
                bytes32 right = 2 * k + 1 < level.length ? level[2 * k + 1] : zero;
                next[k] = Merkle.efficientHash(level[2 * k], right);
            }
            level = next;
            zero = Merkle.efficientHash(zero, zero);
            index >>= 1;
        }
    }

    /// @notice Path of the chain's leaf in the current shared tree.
    function sharedTreePath(uint256 _chainId) external view returns (bytes32[] memory path, uint256 index) {
        index = chainIndex[_chainId];
        path = sharedTree.merklePath(index);
    }

    function _addNewChain(uint256 _chainId, address _chain) internal {
        chainIndex[_chainId] = chainCount++;
        chainContract[_chainId] = _chain;
        chainTree[_chainId].setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
        _recordHistoricalRoot(sharedTree.pushNewLeaf(MessageHashing.chainIdLeafHash(bytes32(0), _chainId)));
    }

    /// @dev MessageRootBase._pushChainBatchRoot.
    function _push(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) internal {
        uint256 l1Timestamp = block.timestamp;
        chainBatchRootTimestamp[_chainId][_batchNumber] = l1Timestamp;
        bytes32 leaf = MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber, l1Timestamp);
        chainLeaves[_chainId].push(leaf);
        (, bytes32 chainRoot) = chainTree[_chainId].push(leaf);
        bytes32 root = sharedTree.updateLeaf(chainIndex[_chainId], MessageHashing.chainIdLeafHash(chainRoot, _chainId));
        _recordHistoricalRoot(root);
    }

    function _recordHistoricalRoot(bytes32 _root) internal {
        historicalRoots[block.number] = StoredInteropRoot({root: _root, timestamp: block.timestamp});
    }
}
