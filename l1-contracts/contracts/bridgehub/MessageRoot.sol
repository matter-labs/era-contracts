// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";

import {IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

import {FullMerkle} from "../common/libraries/FullMerkle.sol";

import {MessageHashing} from "../common/libraries/MessageHashing.sol";

import {MAX_NUMBER_OF_HYPERCHAINS} from "../common/Config.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract MessageRoot is IMessageRoot, ReentrancyGuard {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    event AddedChain(uint256 indexed chainId, uint256 indexed chainIndex);

    event AppendedChainBatchRoot(uint256 indexed chainId, uint256 indexed batchNumber, bytes32 batchRoot);

    event Preimage(bytes32 one, bytes32 two);

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The number of chains that are registered.
    uint256 public chainCount;

    /// @notice The mapping from chainId to chainIndex.
    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    /// @notice The mapping from chainIndex to chainId.
    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    // There are two ways to distinguish chains:
    // - Either by reserving the index 0 as a special value which denotes an unregistered chain
    // - Use a separate mapping
    // The second approach is used due to explicitness.
    /// @notice The mapping from chainId to whether the chain is registered. Used because the chainIndex can be 0.
    mapping(uint256 chainId => bool isRegistered) public chainRegistered;

    /// @notice The shared full merkle tree storing the aggregate hash.
    FullMerkle.FullTree public sharedTree;

    /// @dev The incremental merkle tree storing the chain message roots.
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "MR: only bridgehub");
        _;
    }

    /// @notice only the bridgehub can call
    /// @param _chainId the chainId of the chain
    modifier onlyChain(uint256 _chainId) {
        require(msg.sender == BRIDGE_HUB.getHyperchain(_chainId), "MR: only chain");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;
        _initialize();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external reentrancyGuardInitializer {
        _initialize();
    }

    function addNewChain(uint256 _chainId) external onlyBridgehub {
        require(!chainRegistered[_chainId], "MR: chain exists");
        _addNewChain(_chainId);
    }

    /// @dev Adds a new chain to the message root if it has not been added yet.
    /// @param _chainId the chainId of the chain
    function addNewChainIfNeeded(uint256 _chainId) external onlyBridgehub {
        if (!chainRegistered[_chainId]) {
            _addNewChain(_chainId);
        }
    }

    /// @dev add a new chainBatchRoot to the chainTree
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) external onlyChain(_chainId) {
        require(chainRegistered[_chainId], "MR: not registered");
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber));

        // slither-disable-next-line unused-return
        sharedTree.updateLeaf(chainIndex[_chainId], MessageHashing.chainIdLeafHash(chainRoot, _chainId));

        emit Preimage(chainRoot, MessageHashing.chainIdLeafHash(chainRoot, _chainId));

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);
    }

    /// @dev Gets the aggregated root of all chains.
    function getAggregatedRoot() external view returns (bytes32) {
        return sharedTree.root();
    }

    /// @dev Gets the message root of a single chain.
    /// @param _chainId the chainId of the chain
    function getChainRoot(uint256 _chainId) external view returns (bytes32) {
        return chainTree[_chainId].root();
    }

    function updateFullTree() public {
        uint256 cachedChainCount = chainCount;
        bytes32[] memory newLeaves = new bytes32[](cachedChainCount);
        for (uint256 i = 0; i < cachedChainCount; ++i) {
            newLeaves[i] = MessageHashing.chainIdLeafHash(chainTree[chainIndexToId[i]].root(), chainIndexToId[i]);
        }
        // slither-disable-next-line unused-return
        sharedTree.updateAllLeaves(newLeaves);
    }

    function _initialize() internal {
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
    }

    /// @dev Adds a single chain to the message root.
    /// @param _chainId the chainId of the chain
    function _addNewChain(uint256 _chainId) internal {
        // The chain itself can not be the part of the message root.
        // The message root will only aggregate chains that settle on it.
        require(_chainId != block.chainid, "MR: chainId is this chain");

        chainRegistered[_chainId] = true;

        // We firstly increment `chainCount` and then apply it to ensure that `0` is reserved for chains that are not present.
        uint256 cachedChainCount = chainCount;
        require(cachedChainCount < MAX_NUMBER_OF_HYPERCHAINS, "MR: too many chains");

        ++chainCount;
        chainIndex[_chainId] = cachedChainCount;
        chainIndexToId[cachedChainCount] = _chainId;

        // slither-disable-next-line unused-return
        bytes32 initialHash = chainTree[_chainId].setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
        // slither-disable-next-line unused-return
        sharedTree.pushNewLeaf(MessageHashing.chainIdLeafHash(initialHash, _chainId));

        emit AddedChain(_chainId, cachedChainCount);
    }
}
