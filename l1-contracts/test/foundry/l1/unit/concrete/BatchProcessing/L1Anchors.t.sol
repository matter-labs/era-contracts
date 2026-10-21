// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {CommitBatchInfoZKsyncOS, ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {TestCommitter} from "contracts/dev-contracts/test/TestCommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {L1_ANCHOR_MAX_LAG, L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {
    InvalidInteropRootTimestamp,
    L1AnchorTooOld,
    MessageRootIsZero
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice L1SLOAD anchors through a real diamond and a real `L1MessageRoot`: commits record anchors, an imported
/// anchor must match the L1 record at execution, and the chain's newest anchor must be fresh relative to each
/// executed batch.
/// See {protocol-docs/l1sload.md}.
contract L1AnchorsExecutorTest is ExecutorTest {
    uint256 internal constant BLOCK_1 = 1000;
    uint256 internal constant BLOCK_2 = 2000;
    bytes32 internal constant HASH_1 = keccak256("l1-block-1000");
    bytes32 internal constant HASH_2 = keccak256("l1-block-2000");
    string internal constant V35_COMMITTER = "test/foundry/l1/integration/fixtures/v35/CommitterFacet.json";

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
        assertEq(utilsFacet.util_getL1AnchorTimestamp(), recordedAt, "the newest anchor is tracked");
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
                                Freshness
    //////////////////////////////////////////////////////////////*/

    function test_freshness_batchUpToTheLagExecutes() public {
        (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt) = _executeFirstBatchWithAnchor();

        IExecutor.StoredBatchInfo memory second = _commitAndProveSecond(first, anchoredAt + L1_ANCHOR_MAX_LAG);
        _execute(second, new InteropRoot[](0));

        assertEq(getters.getTotalBatchesExecuted(), 2);
        assertEq(utilsFacet.util_getL1AnchorTimestamp(), anchoredAt, "no new anchor");
    }

    function test_freshness_revertWhen_batchIsPastTheLag() public {
        (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt) = _executeFirstBatchWithAnchor();
        uint256 batchTimestamp = anchoredAt + L1_ANCHOR_MAX_LAG + 1;

        IExecutor.StoredBatchInfo memory second = _commitAndProveSecond(first, batchTimestamp);
        assertEq(second.timestamp, batchTimestamp, "the stored batch carries its last L2 block timestamp");

        vm.expectRevert(abi.encodeWithSelector(L1AnchorTooOld.selector, anchoredAt, batchTimestamp));
        _execute(second, new InteropRoot[](0));
        assertEq(getters.getTotalBatchesExecuted(), 1);
    }

    /// @dev The rule holds exactly at the lag boundary, for any distance from the anchor.
    function testFuzz_freshness_executesIffWithinTheLag(uint256 _distance) public {
        uint256 distance = bound(_distance, 0, 3 * L1_ANCHOR_MAX_LAG);
        (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt) = _executeFirstBatchWithAnchor();
        uint256 batchTimestamp = anchoredAt + distance;
        IExecutor.StoredBatchInfo memory second = _commitAndProveSecond(first, batchTimestamp);

        if (distance > L1_ANCHOR_MAX_LAG) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorTooOld.selector, anchoredAt, batchTimestamp));
        }
        _execute(second, new InteropRoot[](0));
        assertEq(getters.getTotalBatchesExecuted(), distance > L1_ANCHOR_MAX_LAG ? 1 : 2);
    }

    /// @dev The stale batch executes once it imports a newer anchor itself.
    function test_freshness_batchImportingANewerAnchorExecutes() public {
        (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt) = _executeFirstBatchWithAnchor();
        uint256 batchTimestamp = anchoredAt + L1_ANCHOR_MAX_LAG + 1;
        vm.warp(batchTimestamp);
        uint256 newAnchoredAt = _recordL1BlockHash(BLOCK_2, HASH_2);
        InteropRoot[] memory roots = _single(_anchor(BLOCK_2, HASH_2, newAnchoredAt));

        IExecutor.StoredBatchInfo memory second = _commitAndProve(first, _batch(2, batchTimestamp, roots));
        _mockMessageRootAppend(2);
        _execute(second, roots);

        assertEq(getters.getTotalBatchesExecuted(), 2);
        assertEq(utilsFacet.util_getL1AnchorTimestamp(), newAnchoredAt);
    }

    /// @dev `L2InteropRootStorage` refuses an anchor that isn't newer than the chain's current one, but the executor
    /// doesn't rely on that: an older anchor never lowers the tracked timestamp.
    function test_freshness_olderAnchorKeepsTheNewest() public {
        uint256 olderAt = _recordL1BlockHash(BLOCK_1, HASH_1);
        vm.warp(block.timestamp + 100);
        uint256 newerAt = _recordL1BlockHash(BLOCK_2, HASH_2);
        InteropRoot[] memory newer = _single(_anchor(BLOCK_2, HASH_2, newerAt));
        IExecutor.StoredBatchInfo memory first = _commitAndProveFirst(newer);
        _execute(first, newer);

        InteropRoot[] memory older = _single(_anchor(BLOCK_1, HASH_1, olderAt));
        IExecutor.StoredBatchInfo memory second = _commitAndProve(first, _batch(2, block.timestamp, older));
        _mockMessageRootAppend(2);
        _execute(second, older);

        assertEq(utilsFacet.util_getL1AnchorTimestamp(), newerAt);
    }

    /// @dev Priority Mode batches can't import anchors, so the rule is off while it is active.
    function test_freshness_notEnforcedInPriorityMode() public {
        (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt) = _executeFirstBatchWithAnchor();
        uint256 batchTimestamp = anchoredAt + L1_ANCHOR_MAX_LAG + 1;
        IExecutor.StoredBatchInfo memory second = _commitAndProveSecond(first, batchTimestamp);

        // Only the activation flag and the permissionless validator matter on the execute path; activating Priority
        // Mode through `AdminFacet` needs an expired priority operation, which is irrelevant here.
        address permissionlessExecutor = makeAddr("permissionlessExecutor");
        utilsFacet.util_setPriorityModeActivated(true);
        utilsFacet.util_setPriorityModePermissionlessValidator(permissionlessExecutor);

        _execute(second, new InteropRoot[](0), permissionlessExecutor);
        assertEq(getters.getTotalBatchesExecuted(), 2);
    }

    /// @dev A chain that never imported an anchor is not bound by the rule, however old the L1 record is.
    function test_freshness_notEnforcedWithoutAnyAnchor() public {
        _recordL1BlockHash(BLOCK_1, HASH_1);
        vm.warp(block.timestamp + 10 * L1_ANCHOR_MAX_LAG);

        IExecutor.StoredBatchInfo memory stored = _commitAndProveFirst(new InteropRoot[](0));
        _execute(stored, new InteropRoot[](0));

        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(utilsFacet.util_getL1AnchorTimestamp(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        Anchor recorded on commit
    //////////////////////////////////////////////////////////////*/

    /// @dev Decision 7 of the L1SLOAD spec: operators need no separate transaction to record anchors.
    function test_commit_recordsThePreviousL1Block() public {
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
        assertEq(utilsFacet.util_getL1AnchorTimestamp(), recordedAt);
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
                        Batches committed before v36
    //////////////////////////////////////////////////////////////*/

    /// @dev The v35 `CommitterFacet` stores `StoredBatchInfo.timestamp = 0`. Such a batch passes the freshness rule
    /// however old the chain's anchor is. The upgrade engines execute every committed batch before a chain upgrades,
    /// so in production it never meets an anchor; this pins the defensive skip. The real v35 facet commits it
    /// (`fixtures/v35/CommitterFacet.json`), installed with a diamond cut as an upgrade would.
    function test_freshness_batchCommittedByTheV35CommitterIsNotChecked() public {
        (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt) = _executeFirstBatchWithAnchor();
        vm.warp(anchoredAt + 10 * L1_ANCHOR_MAX_LAG);

        _replaceCommitter(deployCode(V35_COMMITTER, abi.encode(block.chainid)));
        CommitBatchInfoZKsyncOS memory info = _batch(2, block.timestamp, new InteropRoot[](0));
        // The v35 Committer checks the six-word chain config hash.
        info.chainConfigHash = keccak256(
            abi.encodePacked(
                l2ChainId,
                uint256(0),
                uint256(getters.getZKsyncOSMaxTxGasLimit()),
                uint256(getters.getPubdataContent()),
                uint256(0),
                uint256(0)
            )
        );
        IExecutor.StoredBatchInfo memory second = _commitBatch(first, info);
        second.timestamp = 0;
        assertEq(getters.storedBatchHash(2), keccak256(abi.encode(second)), "v35 stores timestamp 0");
        _replaceCommitter(address(new TestCommitter()));

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = second;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(first, batches, proofInput);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);
        _mockMessageRootAppend(2);
        _execute(second, new InteropRoot[](0));

        assertEq(getters.getTotalBatchesExecuted(), 2);
        assertEq(utilsFacet.util_getL1AnchorTimestamp(), anchoredAt);
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

    /// @dev Commits, proves and executes batch 1 importing a fresh anchor of L1 block `BLOCK_1`.
    function _executeFirstBatchWithAnchor()
        internal
        returns (IExecutor.StoredBatchInfo memory first, uint256 anchoredAt)
    {
        anchoredAt = _recordL1BlockHash(BLOCK_1, HASH_1);
        InteropRoot[] memory roots = _single(_anchor(BLOCK_1, HASH_1, anchoredAt));
        first = _commitAndProveFirst(roots);
        _execute(first, roots);
    }

    /// @dev Commits `_batchInfo` on top of `_prev` without proving it.
    function _commitBatch(
        IExecutor.StoredBatchInfo memory _prev,
        CommitBatchInfoZKsyncOS memory _batchInfo
    ) internal returns (IExecutor.StoredBatchInfo memory) {
        return _commitOSBatchGetStored(_prev, _batchInfo);
    }

    /// @dev Points `commitBatchesSharedBridge` at `_facet`, through the CTM's `executeUpgrade` as an upgrade does.
    function _replaceCommitter(address _facet) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ICommitter.commitBatchesSharedBridge.selector;
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: _facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: selectors
        });
        vm.prank(getters.getChainTypeManager());
        admin.executeUpgrade(Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: ""}));
    }

    /// @dev Commits and proves batch 1, importing `_roots`, at the current time.
    function _commitAndProveFirst(InteropRoot[] memory _roots) internal returns (IExecutor.StoredBatchInfo memory) {
        return _commitAndProve(genesisStoredBatchInfo, _batch(1, block.timestamp, _roots));
    }

    /// @dev Commits and proves batch 2, without imports, whose L2 blocks end at `_lastBlockTimestamp`.
    function _commitAndProveSecond(
        IExecutor.StoredBatchInfo memory _first,
        uint256 _lastBlockTimestamp
    ) internal returns (IExecutor.StoredBatchInfo memory second) {
        vm.warp(_lastBlockTimestamp);
        second = _commitAndProve(_first, _batch(2, _lastBlockTimestamp, new InteropRoot[](0)));
        _mockMessageRootAppend(2);
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
