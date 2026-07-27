// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";

import {DynamicIncrementalMerkle} from "../../common/libraries/DynamicIncrementalMerkle.sol";

import {CHAIN_TREE_EMPTY_ENTRY_HASH, IMessageRootBase, SHARED_ROOT_TREE_EMPTY_HASH} from "./IMessageRoot.sol";
import {
    BatchZeroNotAllowed,
    ChainBatchRootAlreadyExists,
    ChainBatchRootZero,
    ChainExists,
    DepthMoreThanOneForRecursiveMerkleProof,
    MessageRootNotRegistered,
    NonConsecutiveBatchNumber,
    OnlyBridgehub,
    OnlyChainAssetHandler,
    OnlyBridgehubOrChainAssetHandler,
    OnlyChain
} from "../bridgehub/L1BridgehubErrors.sol";

import {MessageHashing, ProofData} from "../../common/libraries/MessageHashing.sol";
import {StoredInteropRoot} from "../../common/Messaging.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {FullMerkle} from "../../common/libraries/FullMerkle.sol";

import {MessageVerification} from "../../common/MessageVerification.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Stores the chain batch roots of registered chains and aggregates them into a single
/// interop root. From v31 onwards it also verifies L2->L1 messages directly, bypassing the Mailbox
/// of individual chains. See {protocol-docs/message-root.md#aggregation-structure}.
abstract contract MessageRootBase is IMessageRootBase, ReentrancyGuard, Initializable, MessageVerification {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _bridgehub() internal view virtual returns (address);

    function _chainAssetHandler() internal view virtual returns (address);

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() public view virtual returns (uint256);

    /// @notice The number of chains that are registered.
    uint256 public chainCount;

    /// @notice The mapping from chainId to chainIndex. Note index 0 is maintained for the chain the contract is on.
    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    /// @notice The mapping from chainIndex to chainId.
    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    /// @notice The shared full merkle tree storing the aggregate hash.
    /// @dev The chainId leaves are updated on every pushed chain batch root.
    FullMerkle.FullTree public sharedTree;

    /// @dev The incremental merkle tree storing the chain message roots.
    /// @dev A chain's leaves are seeded empty when the chain is added and then pushed to on every
    /// `addChainBatchRoot`.
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice The `(root, timestamp)` recorded per block on every shared-tree update — the tuple
    /// chains import and the executor re-checks at batch execution. See {protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}.
    /// @dev Extending the value type from `bytes32` to `StoredInteropRoot` is layout-safe: mapping
    /// values live at hashed locations and `root` occupies the original slot.
    mapping(uint256 blockNumber => StoredInteropRoot) internal historicalRoots;

    /// @dev Chain ID of L1.
    /// @dev Kept here for storage layout compatibility with previous versions.
    uint256 internal DEPRECATED_l1ChainId;

    /// @notice The mapping from chainId to its current executed batch number.
    /// @dev We store the current batch number for each chain once it upgrades to v31. This value is moved between settlement layers
    /// during migration to ensure consistency.
    mapping(uint256 chainId => uint256 currentChainBatchNumber) public currentChainBatchNumber;

    /// @notice The mapping from chainId to batchNumber to chainBatchRoot.
    /// @dev These are the same values as the leaves of the chainTree.
    /// @dev We store these values for message verification.
    /// @dev An expected invariant is that for all batches starting from currentChainBatchNumber + 1, the `chainBatchRoots` is 0.
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 chainRoot)) public chainBatchRoots;

    /// @notice The current logId value emitted in `NewInteropRoot` events; increments at most once
    /// per block, counting from v31 only.
    uint256 public interopRootLogId;

    /// @notice The block number at which the last interop root was emitted; used to advance the
    /// logId only once per block.
    uint256 public lastEmitBlock;

    /// @notice The settlement-layer `l1Timestamp` at which each `(chainId, batchNumber)` chainBatchRoot was
    /// aggregated. Same value bound into the batch leaf (`MessageHashing.batchLeafHash`), so off-chain proof
    /// builders can read the exact timestamp to feed into a proof.
    /// @dev Appended here (consuming one `__gap` slot) to avoid shifting the pre-existing v31 storage layout.
    mapping(uint256 chainId => mapping(uint256 batchNumber => uint256 l1Timestamp)) public chainBatchRootTimestamp;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[34] private __gap;

    /// @notice Checks that the message sender is the bridgehub or the chain asset handler.
    modifier onlyBridgehubOrChainAssetHandler() {
        if (msg.sender != _bridgehub() && msg.sender != _chainAssetHandler()) {
            revert OnlyBridgehubOrChainAssetHandler(msg.sender, address(_bridgehub()), _chainAssetHandler());
        }
        _;
    }

    /// @notice Checks that the message sender is the chain asset handler.
    modifier onlyChainAssetHandler() {
        if (msg.sender != _chainAssetHandler()) {
            revert OnlyChainAssetHandler(msg.sender, _chainAssetHandler());
        }
        _;
    }

    /// @notice Checks that the message sender is the specified ZK Chain.
    /// @param _chainId The ID of the chain that is required to be the caller.
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != IBridgehubBase(_bridgehub()).getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, IBridgehubBase(_bridgehub()).getZKChain(_chainId));
        }
        _;
    }

    /// @notice Restricts batch-root appends to the chain's own diamond (its `Executor` calls
    /// directly while settling).
    modifier addChainBatchRootRestriction(uint256 _chainId) {
        if (msg.sender != IBridgehubBase(_bridgehub()).getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, IBridgehubBase(_bridgehub()).getZKChain(_chainId));
        }
        _;
    }

    function _initialize() internal {
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
        _addNewChain(block.chainid, 0);
    }

    /// @inheritdoc IMessageRootBase
    function addNewChain(uint256 _chainId, uint256 _startingBatchNumber) external onlyBridgehubOrChainAssetHandler {
        if (chainRegistered(_chainId)) {
            revert ChainExists();
        }
        _addNewChain(_chainId, _startingBatchNumber);
    }

    /// @inheritdoc IMessageRootBase
    function setMigratingChainBatchNumber(uint256 _chainId, uint256 _batchNumber) external onlyChainAssetHandler {
        // `<=` because a chain may migrate to GW and return to L1 without committing any batches on GW.
        require(currentChainBatchNumber[_chainId] <= _batchNumber, ChainBatchRootAlreadyExists(_chainId, _batchNumber));
        currentChainBatchNumber[_chainId] = _batchNumber;
    }

    function chainRegistered(uint256 _chainId) public view returns (bool) {
        return (_chainId == block.chainid || chainIndex[_chainId] != 0);
    }

    /// @inheritdoc IMessageRootBase
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) public virtual addChainBatchRootRestriction(_chainId) {
        _recordChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);
    }

    /// @inheritdoc IMessageRootBase
    function addChainBatchRootV32(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) public virtual addChainBatchRootRestriction(_chainId) {
        _recordChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);
        _pushChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);
    }

    /// @dev Shared validation + bookkeeping of both add-chain-batch-root flows.
    function _recordChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) internal {
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        require(_chainBatchRoot != bytes32(0), ChainBatchRootZero());
        require(
            chainBatchRoots[_chainId][_batchNumber] == bytes32(0),
            ChainBatchRootAlreadyExists(_chainId, _batchNumber)
        );
        uint256 expectedNewChainBatchNumber = currentChainBatchNumber[_chainId] + 1;
        require(_batchNumber == expectedNewChainBatchNumber, NonConsecutiveBatchNumber(_chainId, _batchNumber));

        chainBatchRoots[_chainId][_batchNumber] = _chainBatchRoot;
        currentChainBatchNumber[_chainId] = expectedNewChainBatchNumber;
    }

    /// @dev Pushes an already-recorded chainBatchRoot into the chain tree and propagates the new chain
    /// root into the shared tree (the interop half of the v32 flow). See {protocol-docs/message-root.md#v31-vs-v32-append-flows}.
    function _pushChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) internal {
        uint256 l1Timestamp = block.timestamp;
        chainBatchRootTimestamp[_chainId][_batchNumber] = l1Timestamp;

        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(
            MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber, l1Timestamp)
        );

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot, l1Timestamp);

        bytes32 cachedChainIdLeafHash = MessageHashing.chainIdLeafHash(chainRoot, _chainId);
        bytes32 sharedTreeRoot = sharedTree.updateLeaf(chainIndex[_chainId], cachedChainIdLeafHash);

        emit NewChainRoot(_chainId, chainRoot, cachedChainIdLeafHash);

        _emitRoot(sharedTreeRoot);
        _recordHistoricalRoot(sharedTreeRoot);
    }

    /// @dev Records the current shared tree root together with its creation timestamp.
    function _recordHistoricalRoot(bytes32 _sharedTreeRoot) internal {
        historicalRoots[block.number] = StoredInteropRoot({root: _sharedTreeRoot, timestamp: block.timestamp});
    }

    /// @inheritdoc IMessageRootBase
    function historicalRoot(uint256 _blockNumber) external view returns (StoredInteropRoot memory) {
        return historicalRoots[_blockNumber];
    }

    /// @notice Emits a new interop root event when the shared tree root changes.
    function _emitRoot(bytes32 _root) internal {
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = _root;

        uint256 currentCount = interopRootLogId;
        if (block.number != lastEmitBlock) {
            ++currentCount;
            interopRootLogId = currentCount;
            lastEmitBlock = block.number;
        }

        // solhint-disable-next-line func-named-parameters
        emit NewInteropRoot(block.chainid, block.number, currentCount, block.timestamp, _sides);
    }

    /// @notice Gets the aggregated root of all chains.
    function getAggregatedRoot() external view returns (bytes32) {
        if (chainCount == 0) {
            return SHARED_ROOT_TREE_EMPTY_HASH;
        }
        return sharedTree.root();
    }

    /// @inheritdoc IMessageRootBase
    function chainTreeLeafCount(uint256 _chainId) external view returns (uint256) {
        return chainTree[_chainId]._nextLeafIndex;
    }

    /// @notice Gets the message root of a single chain.
    /// @param _chainId The ID of the chain whose message root is being queried.
    function getChainRoot(uint256 _chainId) external view returns (bytes32) {
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        return chainTree[_chainId].root();
    }

    /// @dev Adds a single chain to the message root with an empty chain tree. Genesis seeding of
    /// freshly created ZKsync OS chains happens separately via {seedGenesisRoot}; see
    /// {protocol-docs/chain-lifecycle.md#genesis-batch-root-seeding-messagerootseedgenesisroot}.
    /// @param _chainId The ID of the chain that is being added to the message root.
    /// @param _startingBatchNumber The batch number the chain's numbering continues from on this layer.
    function _addNewChain(uint256 _chainId, uint256 _startingBatchNumber) internal {
        uint256 cachedChainCount = chainCount;

        // The bridgehub (the only registrar) is responsible for keeping the chain count within limits.
        ++chainCount;
        chainIndex[_chainId] = cachedChainCount;
        chainIndexToId[cachedChainCount] = _chainId;
        currentChainBatchNumber[_chainId] = _startingBatchNumber;

        // slither-disable-next-line unused-return
        chainTree[_chainId].setup(CHAIN_TREE_EMPTY_ENTRY_HASH);

        bytes32 sharedTreeRoot = sharedTree.pushNewLeaf(MessageHashing.chainIdLeafHash(bytes32(0), _chainId));

        emit AddedChain(_chainId, cachedChainCount);

        _emitRoot(sharedTreeRoot);
        _recordHistoricalRoot(sharedTreeRoot);
    }

    /// @inheritdoc IMessageRootBase
    function seedGenesisRoot(uint256 _chainId) external {
        if (msg.sender != _bridgehub()) {
            revert OnlyBridgehub(msg.sender, _bridgehub());
        }
        IGetters zkChain = IGetters(IBridgehubBase(_bridgehub()).getZKChain(_chainId));
        if (!zkChain.getZKsyncOS()) {
            return;
        }
        // A ZKsync OS chain always stores its genesis root in DiamondInit; a zero read is a bug.
        bytes32 genesisChainBatchRoot = zkChain.l2LogsRootHash(0);
        require(genesisChainBatchRoot != bytes32(0), ChainBatchRootZero());
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        // Only fresh chains: rules out non-zero starting batches and chains that already pushed batches.
        require(currentChainBatchNumber[_chainId] == 0, NonConsecutiveBatchNumber(_chainId, 0));
        require(chainBatchRoots[_chainId][0] == bytes32(0), ChainBatchRootAlreadyExists(_chainId, 0));

        chainBatchRoots[_chainId][0] = genesisChainBatchRoot;
        // `currentChainBatchNumber` stays 0, so the first real batch continues at 1.
        _pushChainBatchRoot(_chainId, 0, genesisChainBatchRoot);
    }

    //////////////////////////////
    //// IMessageVerification ////
    //////////////////////////////

    function _proveL2LeafInclusionOnSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        ProofData memory _proofData,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view virtual returns (bool);

    function _proveL2LeafInclusionRecursive(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view virtual override returns (bool) {
        ProofData memory proofData = MessageHashing._getProofData({
            _chainId: _chainId,
            _batchNumber: _batchNumber,
            _leafProofMask: _leafProofMask,
            _leaf: _leaf,
            _proof: _proof
        });
        if (proofData.finalProofNode) {
            // The proven root must equal the settling chain's recorded batch root (`chainBatchRoots`),
            // never this layer's aggregate root. See {protocol-docs/message-root.md#proof-paths}.
            bytes32 correctBatchRoot = _getChainBatchRoot(_chainId, _batchNumber);
            return correctBatchRoot == proofData.batchSettlementRoot && correctBatchRoot != bytes32(0);
        }
        if (_depth == 1) {
            revert DepthMoreThanOneForRecursiveMerkleProof();
        }

        return
            _proveL2LeafInclusionOnSettlementLayer({
                _chainId: _chainId,
                _batchNumber: _batchNumber,
                _proofData: proofData,
                _proof: _proof,
                _depth: _depth
            });
    }

    /// @dev Returns the recorded batch root for a chain, falling back to `_noBatchFallback` if absent.
    function _getChainBatchRoot(uint256 _chainId, uint256 _batchNumber) internal view returns (bytes32) {
        // In current server the zeroth batch does not have L2->L1 logs.
        require(_batchNumber > 0, BatchZeroNotAllowed());
        bytes32 savedChainBatchRoot = chainBatchRoots[_chainId][_batchNumber];
        if (savedChainBatchRoot != bytes32(0)) {
            return savedChainBatchRoot;
        }

        return _noBatchFallback(_chainId, _batchNumber);
    }

    /// @dev Expected batch root for a batch number with no stored root: on L1, pre-v31 batches are
    /// looked up on the chain itself; on L2 it always returns 0. See {protocol-docs/message-root.md#proof-paths}.
    function _noBatchFallback(uint256 _chainId, uint256 _batchNumber) internal view virtual returns (bytes32);

    /// @inheritdoc IMessageRootBase
    function getProofData(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) public pure returns (ProofData memory) {
        return
            MessageHashing._getProofData({
                _chainId: _chainId,
                _batchNumber: _batchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }

    /// @inheritdoc IMessageRootBase
    function getMerklePathForChain(uint256 _chainId) external view returns (bytes32[] memory) {
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        uint256 index = chainIndex[_chainId];
        return sharedTree.merklePath(index);
    }

    /// @dev Returns `chainTree` by chain id.
    /// @param _chainId Id of the chain to get tree for.
    function getChainTree(uint256 _chainId) external view returns (DynamicIncrementalMerkle.Bytes32PushTree memory) {
        return chainTree[_chainId];
    }
}
