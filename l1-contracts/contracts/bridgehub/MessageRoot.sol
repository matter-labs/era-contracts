// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";

import {IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

import {FullMerkle} from "../common/libraries/FullMerkle.sol";

import {Messaging} from "../common/libraries/Messaging.sol";

import {MAX_NUMBER_OF_HYPERCHAINS} from "../common/Config.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

contract MessageRoot is IMessageRoot, ReentrancyGuard {
    event AddedChain(uint256 indexed chainId, uint256 indexed chainIndex);

    event AppendedChainBatchRoot(uint256 indexed chainId, uint256 indexed batchNumber, bytes32 batchRoot);

    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    uint256 public chainCount;

    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    // There are two ways to distinguish chains:
    // - Either by reserving the index 0 as a special value which denotes an unregistede chain
    // - Use a separate mapping
    // The second approach is used due to explicitness.
    mapping(uint256 chainId => bool isRegistered) public chainRegistered;

    FullMerkle.FullTree public sharedTree;

    /// @dev the incremental merkle tree storing the chain message roots
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "MR: only bridgehub");
        _;
    }

    /// @notice only the bridgehub can call
    modifier onlyChain(uint256 _chainId) {
        require(msg.sender == BRIDGE_HUB.getHyperchain(_chainId), "MR: only chain");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;
        _initialize();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external reentrancyGuardInitializer {
        _initialize();
    }

    function _initialize() internal {
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
    }

    function addNewChain(uint256 _chainId) external onlyBridgehub {
        require(!chainRegistered[_chainId], "MR: chain exists");
        _addNewChain(_chainId);
    }

    function addNewChainIfNeeded(uint256 _chainId) external onlyBridgehub {
        if (!chainRegistered[_chainId]) {
            _addNewChain(_chainId);
        }
    }

    function getAggregatedRoot() external view returns (bytes32) {
        return sharedTree.root();
    }

    function getChainRoot(uint256 _chainId) external view returns (bytes32) {
        return chainTree[_chainId].root();
    }

    function _addNewChain(uint256 _chainId) internal {
        // The chain itself can not be the part of the message root.
        // The message root will only aggregate chains that settle on it.
        require(_chainId != block.chainid);

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
        sharedTree.pushNewLeaf(Messaging.chainIdLeafHash(initialHash, _chainId));

        emit AddedChain(_chainId, cachedChainCount);
    }

    event Preimage(bytes32 one, bytes32 two);

    /// @dev add a new chainBatchRoot to the chainTree
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) external onlyChain(_chainId) {
        require(chainRegistered[_chainId], "MR: not registered");
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(Messaging.batchLeafHash(_chainBatchRoot, _batchNumber));

        // slither-disable-next-line unused-return
        sharedTree.updateLeaf(chainIndex[_chainId], Messaging.chainIdLeafHash(chainRoot, _chainId));

        emit Preimage(chainRoot, Messaging.chainIdLeafHash(chainRoot, _chainId));

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);
    }

    function updateFullTree() public {
        uint256 cachedChainCount = chainCount;
        bytes32[] memory newLeaves = new bytes32[](cachedChainCount);
        for (uint256 i = 0; i < cachedChainCount; ++i) {
            newLeaves[i] = Messaging.chainIdLeafHash(chainTree[chainIndexToId[i]].root(), chainIndexToId[i]);
        }
        // slither-disable-next-line unused-return
        sharedTree.updateAllLeaves(newLeaves);
    }

    // It is expected that the root is present
    // `_updateTree` should be false only if the caller ensures that it is followed by updating the entire tree.
    function _unsafeResetChainRoot(uint256 _index, bool _updateTree) internal {
        uint256 chainId = chainIndexToId[_index];
        bytes32 initialRoot = chainTree[chainId].setup(CHAIN_TREE_EMPTY_ENTRY_HASH);

        if (_updateTree) {
            // slither-disable-next-line unused-return
            sharedTree.updateLeaf(_index, Messaging.chainIdLeafHash(initialRoot, chainId));
        }
    }

    /// IMPORTANT FIXME!!!: split into two: provide pubdata and clear state. The "provide pubdata" part should be used by SL.
    /// NO DA is provided here ATM !!!
    /// @notice To be called by the bootloader by the L1Messenger at the end of the batch to produce the final root and send it to the underlying layer.
    /// @return pubdata The pubdata to be relayed to the DA layer.
    function clearTreeAndProvidePubdata() external returns (bytes memory) {
        // FIXME: access control: only to be called by the l1 messenger.
        // uint256 cachedChainCount = chainCount;
        // // We will send the updated roots for all chains.
        // // While it will mean that we'll pay even for unchanged roots:
        // // - It is the simplest approach
        // // - The alternative is to send pairs of (chainId, root), which is less efficient if at least half of the chains are active.
        // //
        // // There are of course ways to optimize it further, but it will be done in the future.
        // bytes memory pubdata = new bytes(cachedChainCount * 32);
        // for (uint256 i = 0; i < cachedChainCount; i++) {
        //     // It is the responsibility of each chain to provide the roots of its L2->L1 messages if it wants to see those.
        //     // However, for the security of the system as a whole, the chain roots need to be provided for all chains.
        //     bytes32 chainRoot = chainTree[chainIndexToId[i]].root();
        //     assembly {
        //         mstore(add(pubdata, add(32, mul(i, 32))), chainRoot)
        //     }
        //     // Clearing up the state.
        //     // Note that it *does not* delete any storage slots, so in terms of pubdata savings, it is useless.
        //     // However, the chains paid for these changes anyway, so it is considered acceptable.
        //     // In the future, further optimizations will be available.
        //     _unsafeResetChainRoot(i, false);
        // }
        // updateFullTree();
    }
}
