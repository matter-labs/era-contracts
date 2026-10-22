// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchOpen, NoOpenBatch, NotNextBatch} from "../ZKIPLiteErrors.sol";
import {IMT, IMTLeaf, IndexedMerkleTree} from "era/common/libraries/IndexedMerkleTree.sol";
import {ChainBatchRootTree} from "era/common/libraries/ChainBatchRootTree.sol";
import {ImtInsertion} from "../ImtInsertion.sol";
import {ZKIPLiteRegistry} from "../ZKIPLiteRegistry.sol";
import {MockMessageRoot} from "./MockMessageRoot.sol";

/// @notice Stand-in for one chain: its L2 interop commitment tree (the real IndexedMerkleTree library, as in
/// L2InteropCommitmentTree), its committed batches, and its execute path (registry gate, then the
/// message-root append, as ExecutorFacet does). It also records what the off-chain ZKIP prover reads from
/// the chain's DA and state: insertion proofs per batch, and each leg's inclusion proof at the end of its
/// batch.
contract ChainSim {
    using IndexedMerkleTree for IMT;

    struct Inclusion {
        uint256 batchNumber;
        IMTLeaf leaf;
        uint256 index;
        uint256 height;
        bytes32[] path;
    }

    uint256 public immutable chainId;
    ZKIPLiteRegistry public immutable registry;
    MockMessageRoot public immutable messageRoot;

    IMT internal imt;
    uint256[] internal values;
    uint256 public lastCommitted;
    uint256 public lastExecuted;
    bool internal open;
    bytes32 internal batchBegin;
    uint256[] internal pendingValues;

    mapping(uint256 batchNumber => bytes32 root) public committedRoot;
    mapping(uint256 batchNumber => ZKIPLiteRegistry.ChainBatchRootPreimage) internal preimages;
    mapping(uint256 batchNumber => ImtInsertion.Proof[]) internal insertProofs;
    mapping(uint256 batchNumber => uint256[]) internal batchValues;
    mapping(uint256 value => Inclusion) internal inclusions;


    constructor(uint256 _chainId, ZKIPLiteRegistry _registry, MockMessageRoot _messageRoot) {
        chainId = _chainId;
        registry = _registry;
        messageRoot = _messageRoot;
        imt.setup();
    }

    function beginBatch() external {
        require(!open, BatchOpen());
        open = true;
        batchBegin = imt.root();
    }

    /// @notice What AtomicFlowManager.append does to the tree for one leg: insert its commit value.
    function commitLeg(uint256 _value) external {
        require(open, NoOpenBatch());
        uint256 lowIndex = 0;
        uint256 lowValue = 0;
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] < _value && values[i] > lowValue) {
                lowValue = values[i];
                lowIndex = i + 1;
            }
        }
        uint256 leafCount = imt.tree._leafNumber;
        IMTLeaf memory low = imt.leaves[lowIndex];
        bytes32[] memory lowPath = imt.merklePath(lowIndex);
        imt.insert(_value, lowIndex);
        uint256 batchNumber = lastCommitted + 1;
        insertProofs[batchNumber].push();
        ImtInsertion.Proof storage p = insertProofs[batchNumber][insertProofs[batchNumber].length - 1];
        p.low = low;
        p.lowIndex = lowIndex;
        p.lowPath = lowPath;
        p.newPath = imt.merklePath(leafCount);
        values.push(_value);
        batchValues[batchNumber].push(_value);
    }

    /// @notice Seals and commits the batch. `_logsRoot` is opaque here: under variant b' ZKIP never reads logs.
    function endBatch(bytes32 _logsRoot) external returns (uint256 batchNumber) {
        require(open, NoOpenBatch());
        open = false;
        batchNumber = ++lastCommitted;
        bytes32 end = imt.root();
        preimages[batchNumber] = ZKIPLiteRegistry.ChainBatchRootPreimage({
            logsRoot: _logsRoot,
            multichainRoot: bytes32(0),
            imtBegin: batchBegin,
            imtEnd: end
        });
        committedRoot[batchNumber] = ChainBatchRootTree.compute(_logsRoot, bytes32(0), batchBegin, end);
        uint256[] storage added = batchValues[batchNumber];
        for (uint256 i = 0; i < added.length; ++i) {
            uint256 index = imt.valueToIndex[added[i]];
            Inclusion storage inc = inclusions[added[i]];
            inc.batchNumber = batchNumber;
            inc.leaf = imt.leaves[index];
            inc.index = index;
            inc.height = imt.tree._height;
            inc.path = imt.merklePath(index);
        }
    }

    function execute(uint256 _batchNumber) external {
        require(_batchNumber == lastExecuted + 1 && _batchNumber <= lastCommitted, NotNextBatch());
        registry.onExecute(chainId, _batchNumber, preimages[_batchNumber]);
        messageRoot.pushChainBatchRoot(chainId, _batchNumber, committedRoot[_batchNumber]);
        lastExecuted = _batchNumber;
    }

    function imtRoot() external view returns (bytes32) {
        return imt.root();
    }

    function preimage(uint256 _batchNumber) external view returns (ZKIPLiteRegistry.ChainBatchRootPreimage memory) {
        return preimages[_batchNumber];
    }

    function inserts(uint256 _batchNumber) external view returns (ImtInsertion.Proof[] memory) {
        return insertProofs[_batchNumber];
    }

    function legsOf(uint256 _batchNumber) external view returns (uint256[] memory) {
        return batchValues[_batchNumber];
    }

    function inclusion(uint256 _value) external view returns (Inclusion memory) {
        return inclusions[_value];
    }
}
