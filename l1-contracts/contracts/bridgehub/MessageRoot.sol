// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";
import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";

import {IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {OnlyBridgehub, OnlyChain, ChainExists, MessageRootNotRegistered} from "./L1BridgehubErrors.sol";
import {FullMerkle} from "../common/libraries/FullMerkle.sol";

import {MessageHashing} from "../common/libraries/MessageHashing.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// The single shared tree consists of the roots of chain trees as its leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract MessageRoot is IMessageRoot, Initializable {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    event AddedChain(uint256 indexed chainId, uint256 indexed chainIndex);

    event AppendedChainBatchRoot(uint256 indexed chainId, uint256 indexed batchNumber, bytes32 batchRoot);

    event Preimage(bytes32 one, bytes32 two);

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The number of chains that are registered.
    uint256 public chainCount;

    /// @notice The mapping from chainId to chainIndex. Note index 0 is maintained for the chain the contract is on.
    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    /// @notice The mapping from chainIndex to chainId.
    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    /// @notice The shared full merkle tree storing the aggregate hash.
    FullMerkle.FullTree public sharedTree;

    /// @dev The incremental merkle tree storing the chain message roots.
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert OnlyBridgehub(msg.sender, address(BRIDGE_HUB));
        }
        _;
    }

    /// @notice only the bridgehub can call
    /// @param _chainId the chainId of the chain
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, BRIDGE_HUB.getZKChain(_chainId));
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub) {
        BRIDGE_HUB = _bridgehub;
        _initialize();
        _disableInitializers();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external initializer {
        _initialize();
    }

    function addNewChain(uint256 _chainId) external onlyBridgehub {
        if (chainRegistered(_chainId)) {
            revert ChainExists();
        }
        _addNewChain(_chainId);
    }

    function chainRegistered(uint256 _chainId) public view returns (bool) {
        return (_chainId == block.chainid || chainIndex[_chainId] != 0);
    }

    /// @dev add a new chainBatchRoot to the chainTree
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) external onlyChain(_chainId) {
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
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
        if (chainCount == 0) {
            return SHARED_ROOT_TREE_EMPTY_HASH;
        }
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
        _addNewChain(block.chainid);
    }

    /// @dev Adds a single chain to the message root.
    /// @param _chainId the chainId of the chain
    function _addNewChain(uint256 _chainId) internal {
        uint256 cachedChainCount = chainCount;

        // Since only the bridgehub can add new chains to the message root, it is expected that
        // it will be responsible for ensuring that the number of chains does not exceed the limit.
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
