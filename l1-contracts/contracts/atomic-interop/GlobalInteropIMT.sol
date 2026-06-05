// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMerkle} from "../common/libraries/FullMerkle.sol";
import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";
import {IGlobalInteropIMT} from "./IGlobalInteropIMT.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {IMT_EMPTY_LEAF} from "./IAtomicInterop.sol";
import {
    GlobalImtBatchNotIncreasing,
    GlobalImtNotOwner,
    GlobalImtNotSubmitter,
    GlobalImtUnknownBlock,
    GlobalImtZeroOwner,
    GlobalImtZeroRoot,
    GlobalImtZeroSubmitter
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IGlobalInteropIMT}. L1 aggregator of chain interop-IMT roots.
///
/// The global tree is a {FullMerkle} tree whose leaf `i` is `keccak256(chainImtRoot, chainId)`
/// for the chain assigned leaf index `i`. Each `submitChainRoot` updates that chain's leaf in
/// place and snapshots the resulting global root against the current L1 block / timestamp, which
/// is exactly the data L2 importers consume.
contract GlobalInteropIMT is IGlobalInteropIMT {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    /// @notice Owner authorized to manage submitters.
    address public owner;

    /// @dev The aggregated, in-place global tree (leaves are per-chain interop IMT roots).
    FullMerkle.FullTree internal _globalTree;

    /// @dev The append-only history tree of `keccak256(block, timestamp, globalRoot)` snapshots.
    DynamicIncrementalMerkle.Bytes32PushTree internal _historyTree;
    /// @dev globalRoot => L1 block number at which it was appended to the history tree.
    mapping(bytes32 globalRoot => uint256 blockNumber) internal _historyBlockOfRoot;

    /// @dev chainId => assigned leaf index in `_globalTree`.
    mapping(uint256 chainId => uint256 leafIndex) internal _leafIndex;
    /// @dev chainId => registered flag.
    mapping(uint256 chainId => bool registered) internal _registered;
    /// @dev Number of chains registered (next leaf index).
    uint256 public chainLeafCount;

    /// @dev chainId => current interop IMT root.
    mapping(uint256 chainId => bytes32 imtRoot) internal _chainRoot;
    /// @dev chainId => last submitted batch number.
    mapping(uint256 chainId => uint256 batchNumber) internal _currentBatchNumber;
    /// @dev chainId => batchNumber => DA commitment.
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 daCommitment)) internal _daCommitments;

    /// @dev L1 block number => latest global root recorded at that block.
    mapping(uint256 blockNumber => bytes32 globalRoot) internal _globalRootAtBlock;
    /// @dev L1 block number => L1 timestamp recorded for that block.
    mapping(uint256 blockNumber => uint256 timestamp) internal _timestampAtBlock;
    /// @dev Ascending list of distinct L1 block numbers at which a global root was recorded.
    uint256[] internal _historyBlocks;

    /// @dev chainId => submitter => allowed.
    mapping(uint256 chainId => mapping(address submitter => bool allowed)) internal _isSubmitter;
    /// @dev submitter => allowed for any chain (demo operator).
    mapping(address submitter => bool allowed) internal _isGlobalSubmitter;

    modifier onlyOwner() {
        if (msg.sender != owner) revert GlobalImtNotOwner(msg.sender);
        _;
    }

    /// @param _owner The address allowed to manage submitters.
    constructor(address _owner) {
        if (_owner == address(0)) revert GlobalImtZeroOwner();
        owner = _owner;
        // Initialize both trees with the empty-leaf zero value so paths/zeros align with the
        // off-chain engine and the proof library.
        _globalTree.setup(IMT_EMPTY_LEAF);
        _historyTree.setup(IMT_EMPTY_LEAF);
    }

    /// @inheritdoc IGlobalInteropIMT
    function setSubmitter(uint256 _chainId, address _submitter, bool _allowed) external onlyOwner {
        if (_submitter == address(0)) revert GlobalImtZeroSubmitter();
        _isSubmitter[_chainId][_submitter] = _allowed;
        emit SubmitterSet(_chainId, _submitter, _allowed);
    }

    /// @inheritdoc IGlobalInteropIMT
    function setGlobalSubmitter(address _submitter, bool _allowed) external onlyOwner {
        if (_submitter == address(0)) revert GlobalImtZeroSubmitter();
        _isGlobalSubmitter[_submitter] = _allowed;
        emit GlobalSubmitterSet(_submitter, _allowed);
    }

    /// @inheritdoc IGlobalInteropIMT
    function submitChainRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainImtRoot,
        bytes32 _daCommitment
    ) external {
        if (!_isGlobalSubmitter[msg.sender] && !_isSubmitter[_chainId][msg.sender]) {
            revert GlobalImtNotSubmitter(msg.sender, _chainId);
        }
        if (_chainImtRoot == bytes32(0)) revert GlobalImtZeroRoot();

        // Strictly increasing (gaps allowed) prevents replay/regression of a chain's root while
        // keeping batch execution liveness decoupled from exact-consecutive submissions.
        uint256 current = _currentBatchNumber[_chainId];
        if (_batchNumber <= current) {
            revert GlobalImtBatchNotIncreasing(_chainId, current, _batchNumber);
        }

        bytes32 leaf = AtomicInteropProof.globalLeaf(_chainId, _chainImtRoot);
        if (!_registered[_chainId]) {
            uint256 index = chainLeafCount;
            _leafIndex[_chainId] = index;
            _registered[_chainId] = true;
            ++chainLeafCount;
            _globalTree.pushNewLeaf(leaf);
            emit ChainRegistered(_chainId, index);
        } else {
            _globalTree.updateLeaf(_leafIndex[_chainId], leaf);
        }

        _chainRoot[_chainId] = _chainImtRoot;
        _currentBatchNumber[_chainId] = _batchNumber;
        _daCommitments[_chainId][_batchNumber] = _daCommitment;

        bytes32 newGlobalRoot = _globalTree.root();
        if (_globalRootAtBlock[block.number] == bytes32(0)) {
            _historyBlocks.push(block.number);
        }
        _globalRootAtBlock[block.number] = newGlobalRoot;
        _timestampAtBlock[block.number] = block.timestamp;

        // Append the snapshot to the append-only history tree and record its block.
        bytes32 historyLeaf = keccak256(abi.encode(block.number, block.timestamp, newGlobalRoot));
        (uint256 historyIndex, bytes32 newHistoryRoot) = _historyTree.push(historyLeaf);
        if (_historyBlockOfRoot[newGlobalRoot] == 0) {
            _historyBlockOfRoot[newGlobalRoot] = block.number;
        }

        // solhint-disable-next-line func-named-parameters
        emit ChainRootSubmitted(_chainId, _batchNumber, _chainImtRoot, _daCommitment, newGlobalRoot);
        emit GlobalRootUpdated(block.number, block.timestamp, newGlobalRoot);
        // solhint-disable-next-line func-named-parameters
        emit HistoryAppended(historyIndex, block.number, block.timestamp, newGlobalRoot, newHistoryRoot);
    }

    /// @inheritdoc IGlobalInteropIMT
    function globalRoot() external view returns (bytes32) {
        return _globalTree.root();
    }

    /// @inheritdoc IGlobalInteropIMT
    function historyRoot() external view returns (bytes32) {
        return _historyTree.root();
    }

    /// @inheritdoc IGlobalInteropIMT
    function historyLeafCount() external view returns (uint256) {
        return _historyTree._nextLeafIndex;
    }

    /// @inheritdoc IGlobalInteropIMT
    function historyBlockOfRoot(bytes32 _globalRoot) external view returns (uint256) {
        return _historyBlockOfRoot[_globalRoot];
    }

    /// @inheritdoc IGlobalInteropIMT
    function globalRootAtBlock(uint256 _blockNumber) external view returns (bytes32) {
        return _globalRootAtBlock[_blockNumber];
    }

    /// @inheritdoc IGlobalInteropIMT
    function timestampAtBlock(uint256 _blockNumber) external view returns (uint256) {
        return _timestampAtBlock[_blockNumber];
    }

    /// @inheritdoc IGlobalInteropIMT
    function chainRootOf(uint256 _chainId) external view returns (bytes32) {
        return _chainRoot[_chainId];
    }

    /// @inheritdoc IGlobalInteropIMT
    function leafIndexOf(uint256 _chainId) external view returns (uint256) {
        return _leafIndex[_chainId];
    }

    /// @inheritdoc IGlobalInteropIMT
    function isChainRegistered(uint256 _chainId) external view returns (bool) {
        return _registered[_chainId];
    }

    /// @inheritdoc IGlobalInteropIMT
    function currentBatchNumber(uint256 _chainId) external view returns (uint256) {
        return _currentBatchNumber[_chainId];
    }

    /// @inheritdoc IGlobalInteropIMT
    function daCommitmentOf(uint256 _chainId, uint256 _batchNumber) external view returns (bytes32) {
        return _daCommitments[_chainId][_batchNumber];
    }

    /// @inheritdoc IGlobalInteropIMT
    function historyLength() external view returns (uint256) {
        return _historyBlocks.length;
    }

    /// @inheritdoc IGlobalInteropIMT
    function historyBlockAt(uint256 _i) external view returns (uint256) {
        if (_i >= _historyBlocks.length) revert GlobalImtUnknownBlock(_i);
        return _historyBlocks[_i];
    }

    /// @inheritdoc IGlobalInteropIMT
    function merklePathForChain(uint256 _chainId) external view returns (bytes32[] memory) {
        return _globalTree.merklePath(_leafIndex[_chainId]);
    }
}
