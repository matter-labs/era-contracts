// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {InvalidInteropRootTimestamp, MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice L1SLOAD anchors through a real diamond and a real `L1MessageRoot`: the commits of a chain with L1SLOAD on
/// record anchors, and an imported anchor must match the L1 record at execution. See {protocol-docs/l1sload.md#anchors}.
contract L1AnchorsExecutorTest is ExecutorTest {
    uint256 internal constant BLOCK_1 = 1000;
    uint256 internal constant BLOCK_2 = 2000;
    bytes32 internal constant HASH_1 = keccak256("l1-block-1000");
    bytes32 internal constant HASH_2 = keccak256("l1-block-2000");

    function setUp() public {}

    /*//////////////////////////////////////////////////////////////
                        Anchor checked against the record
    //////////////////////////////////////////////////////////////*/

    function test_execute_anchorMatchingTheRecord() public {
        uint256 recordedAt = _recordL1BlockHash(BLOCK_1, HASH_1);
        InteropRoot[] memory roots = _single(_anchor(BLOCK_1, HASH_1, recordedAt));

        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);
        _execute(stored, roots);

        assertEq(getters.getTotalBatchesExecuted(), 1);
    }

    function test_revertWhen_anchorHashDiffersFromTheRecord() public {
        uint256 recordedAt = _recordL1BlockHash(BLOCK_1, HASH_1);
        bytes32 wrongHash = keccak256("not-the-l1-block-hash");
        InteropRoot[] memory roots = _single(_anchor(BLOCK_1, wrongHash, recordedAt));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(abi.encodeWithSelector(InvalidMessageRoot.selector, HASH_1, wrongHash));
        _execute(stored, roots);
        assertEq(getters.getTotalBatchesExecuted(), 0);
    }

    function test_revertWhen_anchorTimestampDiffersFromTheRecord() public {
        uint256 recordedAt = _recordL1BlockHash(BLOCK_1, HASH_1);
        InteropRoot[] memory roots = _single(_anchor(BLOCK_1, HASH_1, recordedAt + 1));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootTimestamp.selector, recordedAt, recordedAt + 1));
        _execute(stored, roots);
    }

    /// @dev A block nobody recorded can't be anchored, even with its true hash.
    function test_revertWhen_anchorBlockNotRecorded() public {
        uint256 recordedAt = _recordL1BlockHash(BLOCK_1, HASH_1);
        InteropRoot[] memory roots = _single(_anchor(BLOCK_1 + 1, HASH_1, recordedAt));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(MessageRootIsZero.selector);
        _execute(stored, roots);
    }

    /*//////////////////////////////////////////////////////////////
                        Anchor recorded on commit
    //////////////////////////////////////////////////////////////*/

    /// @dev Decision 7 of the L1SLOAD spec: operators need no separate transaction to record anchors.
    function test_commit_recordsThePreviousL1Block() public {
        _enableL1Sload();
        vm.roll(BLOCK_2 + 1);
        vm.setBlockhash(BLOCK_2, HASH_2);
        assertEq(messageRoot.recordedL1BlockHash(BLOCK_2).timestamp, 0);

        vm.expectEmit(address(messageRoot));
        emit IL1MessageRoot.L1BlockHashRecorded(BLOCK_2, HASH_2, block.timestamp);
        _commitBatch(genesisStoredBatchInfo, _batch(1, block.timestamp, new InteropRoot[](0)));

        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(BLOCK_2);
        assertEq(recorded.root, HASH_2);
        assertEq(recorded.timestamp, block.timestamp);
    }

    /// @dev Commits don't wait for proofs, so anchors keep being recorded while proving lags.
    function test_commit_recordsWhileProofsLag() public {
        _enableL1Sload();
        vm.roll(BLOCK_1 + 1);
        vm.setBlockhash(BLOCK_1, HASH_1);
        IExecutor.StoredBatchInfo memory first = _commitBatch(
            genesisStoredBatchInfo,
            _batch(1, block.timestamp, new InteropRoot[](0))
        );
        vm.roll(BLOCK_2 + 1);
        vm.setBlockhash(BLOCK_2, HASH_2);
        _commitBatch(first, _batch(2, block.timestamp, new InteropRoot[](0)));

        assertEq(getters.getTotalBatchesCommitted(), 2);
        assertEq(getters.getTotalBatchesVerified(), 0);
        assertEq(messageRoot.recordedL1BlockHash(BLOCK_1).root, HASH_1);
        assertEq(messageRoot.recordedL1BlockHash(BLOCK_2).root, HASH_2);
    }

    /// @dev The chains committing in one L1 block, and the server's keeper, share one record: a second record in the
    /// block writes nothing.
    function test_commit_secondRecordInTheSameL1BlockIsANoop() public {
        _enableL1Sload();
        vm.roll(BLOCK_2 + 1);
        vm.setBlockhash(BLOCK_2, HASH_2);
        _commitBatch(genesisStoredBatchInfo, _batch(1, block.timestamp, new InteropRoot[](0)));
        uint256 recordedAt = block.timestamp;

        vm.warp(block.timestamp + 1);
        vm.recordLogs();
        (uint256 blockNumber, ) = messageRoot.recordL1BlockHash();

        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(blockNumber, BLOCK_2);
        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(BLOCK_2);
        assertEq(recorded.root, HASH_2);
        assertEq(recorded.timestamp, recordedAt, "the first record stays");
    }

    /// @dev The anchor a commit recorded is what a later batch imports.
    function test_commit_recordedAnchorIsImportableByTheNextBatch() public {
        _enableL1Sload();
        vm.roll(BLOCK_1 + 1);
        vm.setBlockhash(BLOCK_1, HASH_1);
        IExecutor.StoredBatchInfo memory first = _commitAndProveFirst(new InteropRoot[](0));
        uint256 recordedAt = block.timestamp;
        _execute(first, new InteropRoot[](0));

        vm.warp(block.timestamp + 1);
        InteropRoot[] memory roots = _single(_anchor(BLOCK_1, HASH_1, recordedAt));
        IExecutor.StoredBatchInfo memory second = _commitAndProve(first, _batch(2, block.timestamp, roots));
        _mockMessageRootAppend(2);
        _execute(second, roots);

        assertEq(getters.getTotalBatchesExecuted(), 2);
    }

    /// @dev A chain with L1SLOAD off reads no L1 state, so its commits record nothing and pay nothing for it.
    function test_commit_recordsNothingWithL1SloadOff() public {
        vm.roll(BLOCK_2 + 1);
        vm.setBlockhash(BLOCK_2, HASH_2);
        vm.expectCall(address(messageRoot), abi.encodeCall(IL1MessageRoot.recordL1BlockHash, ()), 0);

        _commitBatch(genesisStoredBatchInfo, _batch(1, block.timestamp, new InteropRoot[](0)));

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(messageRoot.recordedL1BlockHash(BLOCK_2).timestamp, 0);
    }

    /// @dev Executes record nothing, so anchors don't depend on proofs.
    function test_execute_recordsNothing() public {
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(new InteropRoot[](0));
        vm.roll(BLOCK_2 + 1);
        vm.setBlockhash(BLOCK_2, HASH_2);
        vm.expectCall(address(messageRoot), abi.encodeCall(IL1MessageRoot.recordL1BlockHash, ()), 0);

        _execute(stored, new InteropRoot[](0));

        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(messageRoot.recordedL1BlockHash(BLOCK_2).timestamp, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev Records `_blockHash` as L1 block `_blockNumber` through the real `L1MessageRoot`.
    function _recordL1BlockHash(uint256 _blockNumber, bytes32 _blockHash) internal returns (uint256 recordedAt) {
        vm.roll(_blockNumber + 1);
        vm.setBlockhash(_blockNumber, _blockHash);
        messageRoot.recordL1BlockHash();
        recordedAt = block.timestamp;
    }

    /// @dev Turns L1SLOAD on through the Admin setter; the batches then commit the chain config hash with it.
    function _enableL1Sload() internal {
        vm.prank(getters.getAdmin());
        admin.setZKsyncOSL1SloadEnabled(true);
        newCommitBatchInfoZKsyncOS.chainConfigHash = getters.getZKsyncOSChainConfigHash();
    }

    /// @dev Commits `_batchInfo` on top of `_prev` without proving it.
    function _commitBatch(
        IExecutor.StoredBatchInfo memory _prev,
        CommitBatchInfoZKsyncOS memory _batchInfo
    ) internal returns (IExecutor.StoredBatchInfo memory) {
        return _commitOSBatchGetStored(_prev, _batchInfo);
    }

    /// @dev Commits and proves batch 1, importing `_roots`, at the current time.
    function _commitAndProveFirst(InteropRoot[] memory _roots) internal returns (IExecutor.StoredBatchInfo memory) {
        return _commitAndProve(genesisStoredBatchInfo, _batch(1, block.timestamp, _roots));
    }

    function _anchor(
        uint256 _blockNumber,
        bytes32 _blockHash,
        uint256 _timestamp
    ) internal pure returns (InteropRoot memory anchor) {
        anchor.chainId = L1_BLOCK_HASH_IMPORT_ID;
        anchor.blockOrBatchNumber = _blockNumber;
        anchor.timestamp = _timestamp;
        anchor.sides = new bytes32[](1);
        anchor.sides[0] = _blockHash;
    }

    function _single(InteropRoot memory _root) internal pure returns (InteropRoot[] memory roots) {
        roots = new InteropRoot[](1);
        roots[0] = _root;
    }

    /// @dev Mirrors the executor's rolling hash over the batch's dependency roots.
    function _rollingHash(InteropRoot[] memory _roots) internal pure returns (bytes32 rollingHash) {
        for (uint256 i = 0; i < _roots.length; ++i) {
            rollingHash = keccak256(
                abi.encodePacked(
                    rollingHash,
                    _roots[i].chainId,
                    _roots[i].blockOrBatchNumber,
                    _roots[i].timestamp,
                    _roots[i].sides
                )
            );
        }
    }

    function _batch(
        uint64 _batchNumber,
        uint256 _lastBlockTimestamp,
        InteropRoot[] memory _roots
    ) internal view returns (CommitBatchInfoZKsyncOS memory batch) {
        batch = newCommitBatchInfoZKsyncOS;
        batch.batchNumber = _batchNumber;
        batch.firstBlockTimestamp = uint64(_lastBlockTimestamp);
        batch.lastBlockTimestamp = uint64(_lastBlockTimestamp);
        batch.dependencyRootsRollingHash = _rollingHash(_roots);
    }

    function _commitAndProve(
        IExecutor.StoredBatchInfo memory _prev,
        CommitBatchInfoZKsyncOS memory _batchInfo
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        stored = _commitOSBatchGetStored(_prev, _batchInfo);
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = stored;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(_prev, batches, proofInput);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);
    }

    /// @dev As the fixture does for batch 1: the append to the message root is out of scope here.
    function _mockMessageRootAppend(uint256 _batchNumber) internal {
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRootBase.addChainBatchRootV32.selector, l2ChainId, _batchNumber, bytes32(0)),
            abi.encode()
        );
    }

    function _execute(IExecutor.StoredBatchInfo memory _stored, InteropRoot[] memory _roots) internal {
        _execute(_stored, _roots, validator);
    }

    /// @dev Executes one batch without priority operations, importing `_roots`.
    function _execute(IExecutor.StoredBatchInfo memory _stored, InteropRoot[] memory _roots, address _sender) internal {
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
        vm.prank(_sender);
        executor.executeBatchesSharedBridge(
            address(0),
            _stored.batchNumber,
            _stored.batchNumber,
            bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE), encoded)
        );
    }
}
