// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {L1SloadMockUtils} from "../Interop/L1Sload/L1SloadMockUtils.sol";

import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {L1_ANCHOR_RECORD_INTERVAL} from "contracts/common/Config.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {
    InvalidInteropRootTimestamp,
    L1AnchorNotSupportedOnGateway,
    MessageRootIsZero
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice L1SLOAD anchors through a real diamond and a real `L1MessageRoot`: commits of a chain with interop enabled
/// record anchors, and an imported anchor must match the record at execution. See {protocol-docs/l1sload.md#anchors}.
/// @dev Whether interop is enabled is mocked on the message root, to isolate the Committer from the `enableInterop`
/// checks (covered by `L1MessageRootEnableInterop.t.sol`).
contract L1AnchorsTest is ExecutorTest {
    uint256 internal constant L1_BLOCK = 1000;
    bytes32 internal constant L1_BLOCK_HASH = keccak256("l1-block-1000");

    function setUp() public {}

    function test_execute_anchorMatchingTheRecord() public {
        uint256 recordedAt = _recordL1BlockHash();
        InteropRoot[] memory roots = _single(L1SloadMockUtils.anchorRoot(L1_BLOCK, L1_BLOCK_HASH, recordedAt));

        _execute(_commitAndProveFirst(roots), roots);

        assertEq(getters.getTotalBatchesExecuted(), 1);
    }

    function test_revertWhen_anchorHashDiffersFromTheRecord() public {
        uint256 recordedAt = _recordL1BlockHash();
        bytes32 wrongHash = keccak256("not-the-l1-block-hash");
        InteropRoot[] memory roots = _single(L1SloadMockUtils.anchorRoot(L1_BLOCK, wrongHash, recordedAt));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(abi.encodeWithSelector(InvalidMessageRoot.selector, L1_BLOCK_HASH, wrongHash));
        _execute(stored, roots);
    }

    function test_revertWhen_anchorTimestampDiffersFromTheRecord() public {
        uint256 recordedAt = _recordL1BlockHash();
        InteropRoot[] memory roots = _single(L1SloadMockUtils.anchorRoot(L1_BLOCK, L1_BLOCK_HASH, recordedAt + 1));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootTimestamp.selector, recordedAt, recordedAt + 1));
        _execute(stored, roots);
    }

    /// @dev A block nobody recorded can't be anchored, even with its true hash.
    function test_revertWhen_anchorBlockNotRecorded() public {
        uint256 recordedAt = _recordL1BlockHash();
        InteropRoot[] memory roots = _single(L1SloadMockUtils.anchorRoot(L1_BLOCK + 1, L1_BLOCK_HASH, recordedAt));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(MessageRootIsZero.selector);
        _execute(stored, roots);
    }

    /// @dev A settlement layer's message root keeps no anchor record. Mocked: its `L1_CHAIN_ID` differs from
    /// `block.chainid`, which is what tells the Executor it runs on a settlement layer.
    function test_revertWhen_anchorOnGateway() public {
        uint256 recordedAt = _recordL1BlockHash();
        InteropRoot[] memory roots = _single(L1SloadMockUtils.anchorRoot(L1_BLOCK, L1_BLOCK_HASH, recordedAt));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);
        vm.mockCall(
            address(messageRoot),
            abi.encodeCall(IMessageRootBase.L1_CHAIN_ID, ()),
            abi.encode(block.chainid + 1)
        );

        vm.expectRevert(L1AnchorNotSupportedOnGateway.selector);
        _execute(stored, roots);
    }

    function test_commit_recordsThePreviousL1Block() public {
        _enableInterop();
        _atL1Block(L1_BLOCK + 1);

        vm.expectEmit(address(messageRoot));
        emit IL1MessageRoot.L1BlockHashRecorded(L1_BLOCK, L1_BLOCK_HASH, block.timestamp);
        _commit(genesisStoredBatchInfo, 1);

        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(L1_BLOCK);
        assertEq(recorded.root, L1_BLOCK_HASH);
        assertEq(recorded.timestamp, block.timestamp);
    }

    /// @dev Commits record at most once per `L1_ANCHOR_RECORD_INTERVAL`, about 70k gas each.
    function test_commit_recordsAtMostOncePerInterval() public {
        _enableInterop();
        uint256 start = block.timestamp;
        _atL1Block(L1_BLOCK + 1);
        IExecutor.StoredBatchInfo memory stored = _commit(genesisStoredBatchInfo, 1);

        vm.warp(start + L1_ANCHOR_RECORD_INTERVAL - 1);
        _atL1Block(L1_BLOCK + 2);
        stored = _commit(stored, 2);
        assertEq(messageRoot.recordedL1BlockHash(L1_BLOCK + 1).timestamp, 0);

        vm.warp(start + L1_ANCHOR_RECORD_INTERVAL);
        _atL1Block(L1_BLOCK + 3);
        _commit(stored, 3);
        assertEq(messageRoot.recordedL1BlockHash(L1_BLOCK + 2).timestamp, block.timestamp);
    }

    /// @dev Without interop nothing is recorded, and the check itself runs at most once per interval.
    function test_commit_recordsNothingWithoutInterop() public {
        _atL1Block(L1_BLOCK + 1);
        vm.expectCall(address(messageRoot), abi.encodeCall(IL1MessageRoot.recordL1BlockHash, ()), 0);
        IExecutor.StoredBatchInfo memory stored = _commit(genesisStoredBatchInfo, 1);
        assertEq(messageRoot.recordedL1BlockHash(L1_BLOCK).timestamp, 0);

        vm.expectCall(address(messageRoot), abi.encodeCall(IL1MessageRoot.isInteropEnabled, (l2ChainId)), 0);
        _commit(stored, 2);
    }

    function _enableInterop() internal {
        vm.mockCall(
            address(messageRoot),
            abi.encodeCall(IL1MessageRoot.isInteropEnabled, (l2ChainId)),
            abi.encode(true)
        );
    }

    function _atL1Block(uint256 _blockNumber) internal {
        vm.roll(_blockNumber);
        vm.setBlockhash(_blockNumber - 1, keccak256(abi.encodePacked("l1-block-", vm.toString(_blockNumber - 1))));
    }

    function _recordL1BlockHash() internal returns (uint256 recordedAt) {
        _atL1Block(L1_BLOCK + 1);
        messageRoot.recordL1BlockHash();
        recordedAt = block.timestamp;
    }

    function _single(InteropRoot memory _root) internal pure returns (InteropRoot[] memory roots) {
        roots = new InteropRoot[](1);
        roots[0] = _root;
    }

    /// @dev Batch `_batchNumber` at the current time, committing to `_roots` with the Executor's rolling hash.
    function _batch(
        uint256 _batchNumber,
        InteropRoot[] memory _roots
    ) internal view returns (CommitBatchInfoZKsyncOS memory batch) {
        batch = newCommitBatchInfoZKsyncOS;
        batch.batchNumber = uint64(_batchNumber);
        batch.firstBlockTimestamp = uint64(block.timestamp);
        batch.lastBlockTimestamp = uint64(block.timestamp);
        batch.dependencyRootsRollingHash = bytes32(0);
        for (uint256 i = 0; i < _roots.length; ++i) {
            batch.dependencyRootsRollingHash = keccak256(
                abi.encodePacked(
                    batch.dependencyRootsRollingHash,
                    _roots[i].chainId,
                    _roots[i].blockOrBatchNumber,
                    _roots[i].timestamp,
                    _roots[i].sides
                )
            );
        }
    }

    function _commit(
        IExecutor.StoredBatchInfo memory _previous,
        uint256 _batchNumber
    ) internal returns (IExecutor.StoredBatchInfo memory) {
        return _commitOSBatchGetStored(_previous, _batch(_batchNumber, new InteropRoot[](0)));
    }

    function _commitAndProveFirst(
        InteropRoot[] memory _roots
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        stored = _commitOSBatchGetStored(genesisStoredBatchInfo, _batch(1, _roots));
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = stored;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            proofInput
        );
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);
    }

    function _execute(IExecutor.StoredBatchInfo memory _stored, InteropRoot[] memory _roots) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _stored;
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](1);
        dependencyRoots[0] = _roots;
        bytes memory encoded = abi.encode(
            BatchDecoder.DecodedExecuteData({
                batchesData: batches,
                priorityOpsData: Utils.generatePriorityOps(1, 0),
                dependencyRoots: dependencyRoots
            })
        );
        vm.prank(validator);
        executor.executeBatchesSharedBridge(
            address(0),
            _stored.batchNumber,
            _stored.batchNumber,
            bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE), encoded)
        );
    }
}
