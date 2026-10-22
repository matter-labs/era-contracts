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
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice L1SLOAD anchors through a real diamond and a real `L1MessageRoot`: commits of a chain with L1SLOAD on record
/// anchors, and an imported anchor must match the record at execution. See {protocol-docs/l1sload.md#anchors}.
contract L1AnchorsExecutorTest is ExecutorTest {
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

    /// @dev A block nobody recorded can't be anchored, even with its true hash.
    function test_revertWhen_anchorBlockNotRecorded() public {
        uint256 recordedAt = _recordL1BlockHash();
        InteropRoot[] memory roots = _single(L1SloadMockUtils.anchorRoot(L1_BLOCK + 1, L1_BLOCK_HASH, recordedAt));
        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(roots);

        vm.expectRevert(MessageRootIsZero.selector);
        _execute(stored, roots);
    }

    function test_commit_recordsThePreviousL1Block() public {
        vm.prank(getters.getAdmin());
        admin.setZKsyncOSL1SloadEnabled(true);
        newCommitBatchInfoZKsyncOS.chainConfigHash = getters.getZKsyncOSChainConfigHash();
        vm.roll(L1_BLOCK + 1);
        vm.setBlockhash(L1_BLOCK, L1_BLOCK_HASH);

        vm.expectEmit(address(messageRoot));
        emit IL1MessageRoot.L1BlockHashRecorded(L1_BLOCK, L1_BLOCK_HASH, block.timestamp);
        _commitOSBatchGetStored(genesisStoredBatchInfo, _batch(new InteropRoot[](0)));

        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(L1_BLOCK);
        assertEq(recorded.root, L1_BLOCK_HASH);
        assertEq(recorded.timestamp, block.timestamp);
    }

    function test_commit_recordsNothingWithL1SloadOff() public {
        vm.roll(L1_BLOCK + 1);
        vm.setBlockhash(L1_BLOCK, L1_BLOCK_HASH);
        vm.expectCall(address(messageRoot), abi.encodeCall(IL1MessageRoot.recordL1BlockHash, ()), 0);

        _commitOSBatchGetStored(genesisStoredBatchInfo, _batch(new InteropRoot[](0)));

        assertEq(messageRoot.recordedL1BlockHash(L1_BLOCK).timestamp, 0);
    }

    function _recordL1BlockHash() internal returns (uint256 recordedAt) {
        vm.roll(L1_BLOCK + 1);
        vm.setBlockhash(L1_BLOCK, L1_BLOCK_HASH);
        messageRoot.recordL1BlockHash();
        recordedAt = block.timestamp;
    }

    function _single(InteropRoot memory _root) internal pure returns (InteropRoot[] memory roots) {
        roots = new InteropRoot[](1);
        roots[0] = _root;
    }

    /// @dev Batch 1 at the current time, committing to `_roots` with the executor's rolling hash.
    function _batch(InteropRoot[] memory _roots) internal view returns (CommitBatchInfoZKsyncOS memory batch) {
        batch = newCommitBatchInfoZKsyncOS;
        batch.batchNumber = 1;
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

    function _commitAndProveFirst(
        InteropRoot[] memory _roots
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        stored = _commitOSBatchGetStored(genesisStoredBatchInfo, _batch(_roots));
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
