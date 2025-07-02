// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";
import {IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ChainExists, MessageRootNotRegistered, OnlyBridgehubOrChainAssetHandler, OnlyChain} from "./L1BridgehubErrors.sol";
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

    /// @notice Emitted when a new chain is added to the MessageRoot.
    /// @param chainId The ID of the chain that is being added to the MessageRoot.
    /// @param chainIndex The index of the chain that is being added. Note, that chain where
    /// the MessageRoot contract was deployed has chainIndex of 0, and this event is not emitted for it.
    event AddedChain(uint256 indexed chainId, uint256 indexed chainIndex);

    /// @notice Emitted when a new chain batch root is appended to the chainTree.
    /// @param chainId The ID of the chain whose chain batch root is being added to the chainTree.
    /// @param batchNumber The number of the batch to which chain batch root belongs.
    /// @param chainBatchRoot The value of chain batch root which is being added.
    event AppendedChainBatchRoot(uint256 indexed chainId, uint256 indexed batchNumber, bytes32 chainBatchRoot);

    /// @notice Emitted when a new chainTree root is produced and its corresponding leaf in sharedTree is updated.
    /// @param chainRoot The updated Merkle root of the chainTree after appending the latest batch root.
    /// @param preimage  The Merkle leaf value (chainIdLeafHash) computed from `chainRoot` and the chain’s ID, used to update the shared tree.
    event Preimage(bytes32 chainRoot, bytes32 preimage);

    /// @notice Emitted whenever the sharedTree is updated, and the new InteropRoot (root of the sharedTree) is generated.
    /// @param chainId The ID of the chain where the sharedTree was updated.
    /// @param blockNumber The block number of the block in which the sharedTree was updated.
    /// @param logId The ID of the log emitted when a new InteropRoot. In this release always equal to 0.
    /// @param sides The "sides" of the interop root. In this release which uses proof-based interop the sides is an array
    /// of length one, which only include the interop root itself. More on that in `L2InteropRootStorage` contract.
    event NewInteropRoot(uint256 indexed chainId, uint256 indexed blockNumber, uint256 indexed logId, bytes32[] sides);

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

    /// @notice The mapping from block number to the global message root.
    /// @dev Each block might have multiple txs that change the historical root. You can safely use the final root in the block,
    /// since each new root cumulatively aggregates all prior changes — so the last root always contains (at minimum) everything
    /// from the earlier ones.
    mapping(uint256 blockNumber => bytes32 globalMessageRoot) public historicalRoot;

    /// @notice Checks that the message sender is the bridgehub or the chain asset handler.
    modifier onlyBridgehubOrChainAssetHandler() {
        if (msg.sender != address(BRIDGE_HUB) && msg.sender != address(BRIDGE_HUB.chainAssetHandler())) {
            revert OnlyBridgehubOrChainAssetHandler(
                msg.sender,
                address(BRIDGE_HUB),
                address(BRIDGE_HUB.chainAssetHandler())
            );
        }
        _;
    }

    /// @notice Checks that the message sender is the specified ZK Chain.
    /// @param _chainId The ID of the chain that is required to be the caller.
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, BRIDGE_HUB.getZKChain(_chainId));
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _bridgehub Address of the Bridgehub.
    constructor(IBridgehub _bridgehub) {
        BRIDGE_HUB = _bridgehub;
        _initialize();
        _disableInitializers();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external initializer {
        _initialize();
    }

    /// @notice Adds a single chain to the message root.
    /// @param _chainId The ID of the chain that is being added to the message root.
    function addNewChain(uint256 _chainId) external onlyBridgehubOrChainAssetHandler {
        if (chainRegistered(_chainId)) {
            revert ChainExists();
        }
        _addNewChain(_chainId);
    }

    function chainRegistered(uint256 _chainId) public view returns (bool) {
        return (_chainId == block.chainid || chainIndex[_chainId] != 0);
    }

    /// @notice Adds a new chainBatchRoot to the chainTree.
    /// @param _chainId The ID of the chain whose chainBatchRoot is being added to the chainTree.
    /// @param _batchNumber The number of the batch to which _chainBatchRoot belongs.
    /// @param _chainBatchRoot The value of chainBatchRoot which is being added.
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) external onlyChain(_chainId) {
        // Make sure that chain is registered.
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }

        // Push chainBatchRoot to the chainTree related to specified chainId and get the new root.
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber));

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);

        // Update leaf corresponding to the specified chainId with newly acquired value of the chainRoot.
        bytes32 cachedChainIdLeafHash = MessageHashing.chainIdLeafHash(chainRoot, _chainId);
        bytes32 sharedTreeRoot = sharedTree.updateLeaf(chainIndex[_chainId], cachedChainIdLeafHash);

        emit Preimage(chainRoot, cachedChainIdLeafHash);

        // What happens here is we query for the current sharedTreeRoot and emit the event stating that new InteropRoot is "created".
        // The reason for the usage of "bytes32[] memory _sides" to store the InteropRoot is explained in L2InteropRootStorage contract.
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = sharedTreeRoot;
        emit NewInteropRoot(block.chainid, block.number, 0, _sides);
        historicalRoot[block.number] = sharedTreeRoot;
    }

    /// @notice Gets the aggregated root of all chains.
    function getAggregatedRoot() external view returns (bytes32) {
        if (chainCount == 0) {
            return SHARED_ROOT_TREE_EMPTY_HASH;
        }
        return sharedTree.root();
    }

    /// @dev Gets the message root of a single chain.
    /// @param _chainId The ID of the chain whose message root is being queried.
    function getChainRoot(uint256 _chainId) external view returns (bytes32) {
        return chainTree[_chainId].root();
    }

    function updateFullTree() public {
        uint256 cachedChainCount = chainCount;
        bytes32[] memory newLeaves = new bytes32[](cachedChainCount);
        for (uint256 i = 0; i < cachedChainCount; ++i) {
            uint256 chainId = chainIndexToId[i];
            newLeaves[i] = MessageHashing.chainIdLeafHash(chainTree[chainId].root(), chainId);
        }
        bytes32 newRoot = sharedTree.updateAllLeaves(newLeaves);
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = newRoot;
        emit NewInteropRoot(block.chainid, block.number, 0, _sides);
        historicalRoot[block.number] = newRoot;
    }

    function _initialize() internal {
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
        _addNewChain(block.chainid);
    }

    /// @dev Adds a single chain to the message root.
    /// @param _chainId The ID of the chain that is being added to the message root.
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
