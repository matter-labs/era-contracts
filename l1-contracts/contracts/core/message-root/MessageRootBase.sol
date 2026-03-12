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
    OnlyAssetTracker,
    OnlyBridgehubOrChainAssetHandler,
    OnlyChain
} from "../bridgehub/L1BridgehubErrors.sol";

import {GW_ASSET_TRACKER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

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

    function _eraGatewayChainId() internal view virtual returns (uint256);

    /// @notice The number of chains that are registered.
    uint256 public chainCount;

    /// @notice The mapping from chainId to chainIndex. Note index 0 is maintained for the chain the contract is on.
    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    /// @notice The mapping from chainIndex to chainId.
    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    /// @notice The shared full merkle tree storing the aggregate hash.
    /// @dev Note, that on L1, the chainId leaves are empty.
    FullMerkle.FullTree public sharedTree;

    /// @dev The incremental merkle tree storing the chain message roots.
    /// @dev On L1, these are empty leaves and are populated only during the addition of the chain
    /// are not updated thereafter.
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice The mapping from block number to the global message root.
    /// @dev Each block might have multiple txs that change the historical root. You can safely use the final root in the block,
    /// since each new root cumulatively aggregates all prior changes — so the last root always contains (at minimum) everything
    /// from the earlier ones.
    /// @dev Populated only on L2.
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
    /// @dev We only updated the chainTree on deprecated Era GW as of V31.
    /// @dev An expected invariant is that for all batches starting from currentChainBatchNumber + 1, the `chainBatchRoots` is 0.
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 chainRoot)) public chainBatchRoots;

    /// @notice The total number of published interop roots.
    /// @dev Used inside the `NewInteropRoot` event, used for indexing purposes by the node.
    /// @dev Note that it counts roots starting from V31 ONLY.
    uint256 public totalPublishedInteropRoots;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[36] private __gap;

    /// @notice Checks that the message sender is the bridgehub or the chain asset handler.
    modifier onlyBridgehubOrChainAssetHandler() {
        if (msg.sender != _bridgehub() && msg.sender != _chainAssetHandler()) {
            revert OnlyBridgehubOrChainAssetHandler(msg.sender, address(_bridgehub()), _chainAssetHandler());
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

    /// @notice On L1, the chain can add it directly, while on GW, the asset tracker should add it,
    /// @dev Note, that at the moment of the v31 upgrade we no chains to settle on top of the old
    /// Era-based Gateway, and so no special handling is needed for pre-v31 chains.
    modifier addChainBatchRootRestriction(uint256 _chainId) {
        if (block.chainid != L1_CHAIN_ID()) {
            if (msg.sender != GW_ASSET_TRACKER_ADDR) {
                revert OnlyAssetTracker(msg.sender, GW_ASSET_TRACKER_ADDR);
            }
        } else {
            if (msg.sender != IBridgehubBase(_bridgehub()).getZKChain(_chainId)) {
                revert OnlyChain(msg.sender, IBridgehubBase(_bridgehub()).getZKChain(_chainId));
            }
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
    function setMigratingChainBatchNumber(
        uint256 _chainId,
        uint256 _batchNumber
    ) external onlyBridgehubOrChainAssetHandler {
        // Note, that it is possible that chain migrates to GW and returns to L1 without
        // committing any batches on GW.
        require(currentChainBatchNumber[_chainId] <= _batchNumber, ChainBatchRootAlreadyExists(_chainId, _batchNumber));
        currentChainBatchNumber[_chainId] = _batchNumber;
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
    }

    /// @notice Emits a new interop root event when the shared tree root changes.
    function _emitRoot(bytes32 _root) internal {
        // What happens here is we query for the current sharedTreeRoot and emit the event stating that new InteropRoot is "created".
        // The reason for the usage of "bytes32[] memory _sides" to store the InteropRoot is explained in L2InteropRootStorage contract.
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = _root;

        uint256 currentCount = totalPublishedInteropRoots;
        totalPublishedInteropRoots = currentCount + 1;

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
            // For proof based interop this is the SL InteropRoot at block number _batchNumber
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
