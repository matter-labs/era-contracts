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
    OnlyChainAssetHandler,
    OnlyBridgehubOrChainAssetHandler,
    OnlyChain
} from "../bridgehub/L1BridgehubErrors.sol";

import {MessageHashing, ProofData} from "../../common/libraries/MessageHashing.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {FullMerkle} from "../../common/libraries/FullMerkle.sol";

import {MessageVerification} from "../../common/MessageVerification.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
/// @dev From V31 onwards it is also used for L2->L1 message verification, this allows bypassing the Mailbox of individual chains.
/// This is especially useful for chains settling on Gateway.
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
    /// @dev The chainId leaves are updated on every `addChainBatchRoot` on both settlement layers (L1
    /// and Gateway).
    FullMerkle.FullTree public sharedTree;

    /// @dev The incremental merkle tree storing the chain message roots.
    /// @dev A chain's leaves are seeded empty when the chain is added and then pushed to on every
    /// `addChainBatchRoot`, on both settlement layers (L1 and Gateway).
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice The mapping from block number to the global message root.
    /// @dev Each block might have multiple txs that change the historical root. You can safely use the final root in the block,
    /// since each new root cumulatively aggregates all prior changes — so the last root always contains (at minimum) everything
    /// from the earlier ones.
    /// @dev Populated on both settlement layers (L1 and Gateway) on every `addChainBatchRoot`.
    mapping(uint256 blockNumber => bytes32 globalMessageRoot) public historicalRoot;

    /// @dev Chain ID of L1.
    /// @dev Kept here for storage layout compatibility with previous versions.
    uint256 internal DEPRECATED_l1ChainId;

    /// @notice The mapping from chainId to its current executed batch number.
    /// @dev We store the current batch number for each chain once it upgrades to v31. This value is moved between settlement layers
    /// during migration to ensure consistency.
    mapping(uint256 chainId => uint256 currentChainBatchNumber) public currentChainBatchNumber;

    /// @notice The mapping from chainId to batchNumber to chainBatchRoot.
    /// @dev These are the same values as the leaves of the chainTree.
    /// @dev We store these values for message verification on L1 and Gateway.
    /// @dev An expected invariant is that for all batches starting from currentChainBatchNumber + 1, the `chainBatchRoots` is 0.
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 chainRoot)) public chainBatchRoots;

    /// @notice The settlement-layer block timestamp at which each `(chainId, batchNumber)` chainBatchRoot
    /// was aggregated (i.e. when the chain settled on this layer).
    /// @dev This is the same `l1Timestamp` that is bound into the batch leaf (`MessageHashing.batchLeafHash`),
    /// so it is provable via the aggregated-root inclusion proof. Stored so that off-chain proof builders
    /// can retrieve the exact timestamp they must feed into a proof.
    mapping(uint256 chainId => mapping(uint256 batchNumber => uint256 l1Timestamp)) public chainBatchRootTimestamp;

    /// @notice The current logId value emitted in `NewInteropRoot` events.
    /// @dev Increments at most once per block: all emissions within the same block share the same
    /// logId, and the counter only advances when `block.number` changes.
    /// @dev Note that it counts starting from V31 ONLY.
    uint256 public interopRootLogId;

    /// @notice The block number at which the last interop root was emitted.
    /// @dev Used to ensure logId increments per block: within the same block all NewInteropRoot
    /// events share the same logId value, and the counter only advances when the block changes.
    uint256 public lastEmitBlock;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[35] private __gap;

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

    /// @notice The chain itself appends its batch root, both on L1 and on Gateway. On Gateway the
    /// chain's `Executor` calls this directly while settling (it no longer routes through the asset
    /// tracker). Asset correctness across chains is guaranteed by ZK proofs.
    /// @dev Note, that at the moment of the v31 upgrade we no chains to settle on top of the old
    /// Era-based Gateway, and so no special handling is needed for pre-v31 chains.
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

    /// @notice Adds a single chain to the message root.
    /// @param _chainId The ID of the chain that is being added to the message root.
    function addNewChain(uint256 _chainId, uint256 _startingBatchNumber) external onlyBridgehubOrChainAssetHandler {
        if (chainRegistered(_chainId)) {
            revert ChainExists();
        }
        _addNewChain(_chainId, _startingBatchNumber);
    }

    /// @notice During the chain migration, we move the batch number from the old settlement layer to the new one to ensure consistency.
    function setMigratingChainBatchNumber(uint256 _chainId, uint256 _batchNumber) external onlyChainAssetHandler {
        // Note, that it is possible that chain migrates to GW and returns to L1 without
        // committing any batches on GW.
        require(currentChainBatchNumber[_chainId] <= _batchNumber, ChainBatchRootAlreadyExists(_chainId, _batchNumber));
        currentChainBatchNumber[_chainId] = _batchNumber;
    }

    function chainRegistered(uint256 _chainId) public view returns (bool) {
        return (_chainId == block.chainid || chainIndex[_chainId] != 0);
    }

    /// @notice Adds a new chainBatchRoot to the chainTree and updates the aggregated shared tree.
    /// @dev Runs on both settlement layers: on L1 the chain's DiamondProxy calls it directly during
    /// batch execution, on Gateway the GW asset tracker calls it (see `addChainBatchRootRestriction`).
    /// In both cases the chainBatchRoot is recorded, pushed to the chain tree, the shared tree leaf is
    /// updated, and a new interop root is emitted — so chains settling on either layer participate in
    /// interop.
    /// @param _chainId The ID of the chain whose chainBatchRoot is being added to the chainTree.
    /// @param _batchNumber The number of the batch to which _chainBatchRoot belongs.
    /// @param _chainBatchRoot The value of chainBatchRoot which is being added.
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) public virtual addChainBatchRootRestriction(_chainId) {
        // Make sure that chain is registered.
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

        // Record the settlement-layer timestamp at which this batch root was aggregated. It is bound into
        // the batch leaf below, so a later inclusion proof against the aggregated root also proves the
        // timestamp — a single aggregated root can prove many chain batch roots, each with its own time.
        uint256 l1Timestamp = block.timestamp;
        chainBatchRootTimestamp[_chainId][_batchNumber] = l1Timestamp;

        // Push chainBatchRoot to the chainTree related to specified chainId and get the new root.
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(
            MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber, l1Timestamp)
        );

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot, l1Timestamp);

        // Update leaf corresponding to the specified chainId with newly acquired value of the chainRoot.
        bytes32 cachedChainIdLeafHash = MessageHashing.chainIdLeafHash(chainRoot, _chainId);
        bytes32 sharedTreeRoot = sharedTree.updateLeaf(chainIndex[_chainId], cachedChainIdLeafHash);

        emit NewChainRoot(_chainId, chainRoot, cachedChainIdLeafHash);

        _emitRoot(sharedTreeRoot);
        historicalRoot[block.number] = sharedTreeRoot;
    }

    /// @notice Emits a new interop root event when the shared tree root changes.
    /// @dev The logId (interopRootLogId) increments at most once per block. All emissions
    /// within the same block share the same logId so that the server node can group them by block.
    function _emitRoot(bytes32 _root) internal {
        // What happens here is we query for the current sharedTreeRoot and emit the event stating that new InteropRoot is "created".
        // The reason for the usage of "bytes32[] memory _sides" to store the InteropRoot is explained in L2InteropRootStorage contract.
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = _root;

        uint256 currentCount = interopRootLogId;
        if (block.number != lastEmitBlock) {
            ++currentCount;
            interopRootLogId = currentCount;
            lastEmitBlock = block.number;
        }

        emit NewInteropRoot(block.chainid, block.number, currentCount, _sides);
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
        // Make sure that chain is registered.
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        return chainTree[_chainId].root();
    }

    /// @dev Adds a single chain to the message root.
    /// @param _chainId The ID of the chain that is being added to the message root.
    function _addNewChain(uint256 _chainId, uint256 _startingBatchNumber) internal {
        uint256 cachedChainCount = chainCount;

        // Since only the bridgehub can add new chains to the message root, it is expected that
        // it will be responsible for ensuring that the number of chains does not exceed the limit.
        ++chainCount;
        chainIndex[_chainId] = cachedChainCount;
        chainIndexToId[cachedChainCount] = _chainId;
        currentChainBatchNumber[_chainId] = _startingBatchNumber;

        // slither-disable-next-line unused-return
        bytes32 initialHash = chainTree[_chainId].setup(CHAIN_TREE_EMPTY_ENTRY_HASH);

        bytes32 sharedTreeRoot = sharedTree.pushNewLeaf(MessageHashing.chainIdLeafHash(initialHash, _chainId));

        emit AddedChain(_chainId, cachedChainCount);

        _emitRoot(sharedTreeRoot);
        historicalRoot[block.number] = sharedTreeRoot;
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
            // finalProofNode terminates on the settlement layer — in this release always L1 (every chain
            // settles on L1; SL migrations are disabled). The proven root must equal the settling chain's
            // batch root recorded here (`chainBatchRoots`) — NOT this layer's aggregate root
            // (`historicalRoot`), which is only exported to consumers (where L2 verifiers use `interopRoots`).
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

    /// @notice Internal to get the historical batch root for chains.
    function _getChainBatchRoot(uint256 _chainId, uint256 _batchNumber) internal view returns (bytes32) {
        /// In current server the zeroth batch does not have L2->L1 logs.
        require(_batchNumber > 0, BatchZeroNotAllowed());
        bytes32 savedChainBatchRoot = chainBatchRoots[_chainId][_batchNumber];
        if (savedChainBatchRoot != bytes32(0)) {
            return savedChainBatchRoot;
        }

        return _noBatchFallback(_chainId, _batchNumber);
    }

    /// @notice This function is used to prove the return the expected batch root for batch number that is not stored inside the message root.
    /// @dev On L2, it should always return 0, since on newer GW implementation it is guaranteed that all available batch roots are stored inside the message root.
    /// @dev On L1, if the batch was produced before the v31 upgrade, we must query the chain. Once the ZKsync OS CTM's ownership is transferred to the decentralized
    /// governance, we can trust this value completely. Before it happens, we just assume that no ZKsync OS based Gateway is present,
    /// and so the chain can at most damage itself by providing a wrongful batch root for its own batches, but it cannot affect other chains.
    function _noBatchFallback(uint256 _chainId, uint256 _batchNumber) internal view virtual returns (bytes32);

    /// @notice Extracts and returns proof data for settlement layer verification.
    /// @dev Wrapper function around MessageHashing._getProofData for public access.
    /// @dev The caller should check that the proof has recursion at most depth 1, i.e. only a single intermediate Gateway between the chain and L1.
    /// @dev This check is performed when the MessageRoot verifies the proof, so often it can be skipped.
    /// @param _chainId The chain ID where the proof was generated.
    /// @param _batchNumber The batch number containing the proof.
    /// @param _leafProofMask The leaf proof mask for merkle verification.
    /// @param _leaf The leaf hash to verify.
    /// @param _proof The merkle proof array.
    /// @return The extracted proof data including settlement layer information.
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

    /// @dev Returns merkle path in `sharedTree` for a certain chain.
    /// @param _chainId Id of the chain to get merkle path for.
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
