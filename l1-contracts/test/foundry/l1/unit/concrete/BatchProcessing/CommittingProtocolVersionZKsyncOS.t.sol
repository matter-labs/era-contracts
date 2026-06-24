// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {Utils} from "../Utils/Utils.sol";
import {UtilsFacet} from "../Utils/UtilsFacet.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @dev topic0 hashes of the ZKsync OS commit-path events asserted in these tests. They are derived from the
/// canonical event signatures declared in ICommitter.sol and kept as keccak literals to mirror the existing
/// event-assertion style in Committing.t.sol.
bytes32 constant REPORT_PROTOCOL_VERSION_TOPIC = keccak256(
    "ReportCommittedBatchProtocolVersion(uint64,uint256,bytes32)"
);
bytes32 constant BLOCK_COMMIT_TOPIC = keccak256("BlockCommit(uint256,bytes32,bytes32)");
bytes32 constant REPORT_BATCH_RANGE_TOPIC = keccak256("ReportCommittedBatchRangeZKsyncOS(uint64,uint64,uint64)");

/// @notice Shared helpers for asserting the `ReportCommittedBatchProtocolVersion` event emitted on the ZKsync OS
/// commit path. The feature makes the protocol version and the upgrade transaction hash of every committed ZKsync
/// OS batch determinable from on-chain data alone; the Era counterpart lives in CommittingProtocolVersion.t.sol.
abstract contract CommitProtocolVersionZKsyncOSBase is ExecutorTest {
    function isZKsyncOS() internal pure override returns (bool) {
        return true;
    }

    /// @dev Switches the chain to the validium (no-DA) scheme so a commit needs no real pubdata.
    function _enableValidiumDA() internal {
        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(owner);
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);
    }

    /// @dev Builds a minimal valid validium ZKsync OS commit batch with the given number.
    function _validiumBatch(uint64 _batchNumber) internal view returns (CommitBatchInfoZKsyncOS memory batchInfo) {
        batchInfo = newCommitBatchInfoZKsyncOS;
        batchInfo.batchNumber = _batchNumber;
        batchInfo.operatorDAInput = abi.encodePacked(bytes32(0));
        batchInfo.daCommitment = bytes32(0);
        batchInfo.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
    }

    /// @dev Commits a single ZKsync OS batch as the validator while recording the emitted logs.
    function _commitRecordingLogs(
        IExecutor.StoredBatchInfo memory _lastBatch,
        CommitBatchInfoZKsyncOS memory _batch
    ) internal returns (Vm.Log[] memory entries) {
        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = _batch;
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(_lastBatch, batchArray);
        vm.prank(validator);
        vm.recordLogs();
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
        entries = vm.getRecordedLogs();
    }

    /// @dev Returns the single recorded log whose topic0 matches `_topic0`, asserting it was emitted exactly once.
    function _findUniqueLog(Vm.Log[] memory _entries, bytes32 _topic0) internal pure returns (Vm.Log memory found) {
        bool seen = false;
        for (uint256 i = 0; i < _entries.length; ++i) {
            if (_entries[i].topics.length != 0 && _entries[i].topics[0] == _topic0) {
                require(!seen, "duplicate event with the same topic0");
                found = _entries[i];
                seen = true;
            }
        }
        require(seen, "expected event was not emitted");
    }

    /// @dev Mirrors the `batchOutputHash` formula from Committer._commitOneBatchZKsyncOS, parameterized by the
    /// system upgrade transaction hash folded into the commitment.
    function _batchOutputHash(
        CommitBatchInfoZKsyncOS memory _c,
        bytes32 _upgradeTxHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _c.chainId,
                    _c.firstBlockTimestamp,
                    _c.lastBlockTimestamp,
                    uint256(_c.daCommitmentScheme),
                    _c.daCommitment,
                    _c.numberOfLayer1Txs,
                    _c.numberOfLayer2Txs,
                    _c.priorityOperationsHash,
                    _c.l2LogsTreeRoot,
                    _upgradeTxHash,
                    _c.dependencyRootsRollingHash,
                    _c.slChainId
                )
            );
    }

    /// @dev Replicates the StoredBatchInfo that Committer._commitOneBatchZKsyncOS produces for a commit batch,
    /// so a subsequent batch can be committed on top of it.
    function _storedBatchInfo(
        CommitBatchInfoZKsyncOS memory _c,
        bytes32 _upgradeTxHash
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        return
            IExecutor.StoredBatchInfo({
                batchNumber: _c.batchNumber,
                batchHash: _c.newStateCommitment,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: _c.numberOfLayer1Txs,
                priorityOperationsHash: _c.priorityOperationsHash,
                dependencyRootsRollingHash: _c.dependencyRootsRollingHash,
                l2LogsTreeRoot: _c.l2LogsTreeRoot,
                timestamp: 0,
                commitment: _batchOutputHash(_c, _upgradeTxHash)
            });
    }
}

/// @notice Tests for the `ReportCommittedBatchProtocolVersion` event on the ZKsync OS commit path that do not
/// require manipulating chain state (the default harness commits under protocol version 0 with no pending upgrade).
contract CommitProtocolVersionZKsyncOSTest is CommitProtocolVersionZKsyncOSBase {
    /// @notice A committed ZKsync OS batch emits the protocol version it was committed with, and a zero upgrade
    /// transaction hash when there is no pending protocol upgrade.
    function test_emitsProtocolVersionWithZeroUpgradeTxHash() public {
        _enableValidiumDA();

        Vm.Log[] memory entries = _commitRecordingLogs(genesisStoredBatchInfo, _validiumBatch(1));

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(log.emitter, address(committer), "event emitted by the chain diamond");
        assertEq(log.topics[1], bytes32(uint256(1)), "batchNumber");
        // The harness initializes the chain with protocol version 0.
        assertEq(log.topics[2], bytes32(uint256(0)), "protocolVersion equals the chain's protocol version");
        assertEq(log.topics[3], bytes32(0), "no upgrade tx hash for a non-upgrade batch");
    }

    /// @notice The new event is emitted alongside (not instead of) the existing BlockCommit and
    /// ReportCommittedBatchRangeZKsyncOS events, all for the same batch.
    function test_eventCoexistsWithBlockCommitAndBatchRange() public {
        _enableValidiumDA();

        Vm.Log[] memory entries = _commitRecordingLogs(genesisStoredBatchInfo, _validiumBatch(1));

        Vm.Log memory protocolVersionLog = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        Vm.Log memory blockCommitLog = _findUniqueLog(entries, BLOCK_COMMIT_TOPIC);
        Vm.Log memory batchRangeLog = _findUniqueLog(entries, REPORT_BATCH_RANGE_TOPIC);

        assertEq(protocolVersionLog.topics[1], bytes32(uint256(1)), "protocol version event batchNumber");
        assertEq(blockCommitLog.topics[1], bytes32(uint256(1)), "BlockCommit batchNumber");
        assertEq(batchRangeLog.topics[1], bytes32(uint256(1)), "batch range event batchNumber");
    }
}

/// @notice Tests that drive non-default protocol versions and a pending protocol upgrade through real diamond
/// calls (via UtilsFacet) instead of storage-slot overrides.
contract CommitProtocolVersionWithUtilsZKsyncOSTest is CommitProtocolVersionZKsyncOSBase {
    UtilsFacet internal utilsFacet;

    constructor() {
        // Attach UtilsFacet to the diamond through a real upgrade, mirroring ExecutorRevertBatchesTest.
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });
        vm.prank(getters.getChainTypeManager());
        admin.executeUpgrade(diamondCutData);
        utilsFacet = UtilsFacet(address(committer));
    }

    /// @notice The emitted protocol version equals the chain's protocol version at commit time, so it stays
    /// correct for a batch even if later upgrades change the chain's current protocol version.
    function test_emittedProtocolVersionReflectsConfiguredVersion() public {
        _enableValidiumDA();

        // A semver-like packed value (minor = 27, patch = 7); any non-zero value demonstrates the point.
        uint256 configuredProtocolVersion = (uint256(27) << 32) | uint256(7);
        utilsFacet.util_setProtocolVersion(configuredProtocolVersion);
        assertEq(utilsFacet.util_getProtocolVersion(), configuredProtocolVersion, "protocol version set");

        Vm.Log[] memory entries = _commitRecordingLogs(genesisStoredBatchInfo, _validiumBatch(1));

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(log.emitter, address(committer), "event emitted by the chain diamond");
        assertEq(
            log.topics[2],
            bytes32(configuredProtocolVersion),
            "emitted protocol version must equal the version used to commit the batch"
        );
        assertEq(log.topics[3], bytes32(0), "no upgrade tx hash for a non-upgrade batch");
    }

    /// @notice For the first batch committed after a protocol upgrade, the event reports the upgrade transaction
    /// hash, and that hash is the one folded into the batch commitment (so the server can recompute it).
    function test_emitsUpgradeTxHashForUpgradeBatch() public {
        _enableValidiumDA();

        bytes32 expectedUpgradeTxHash = Utils.randomBytes32("upgradeTx");
        // Simulate a pending protocol upgrade whose upgrade batch has not been committed yet.
        utilsFacet.util_setL2SystemContractsUpgradeTxHash(expectedUpgradeTxHash);
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 0, "no upgrade batch recorded yet");

        CommitBatchInfoZKsyncOS memory upgradeBatch = _validiumBatch(1);
        Vm.Log[] memory entries = _commitRecordingLogs(genesisStoredBatchInfo, upgradeBatch);

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(log.emitter, address(committer), "event emitted by the chain diamond");
        assertEq(log.topics[1], bytes32(uint256(1)), "batchNumber");
        assertEq(log.topics[3], expectedUpgradeTxHash, "upgrade tx hash reported for the upgrade batch");

        // The commit must record this batch as the upgrade batch, mirroring Committer._commitBatchesZKsyncOS.
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 1, "upgrade batch number recorded");

        // The reported upgrade tx hash is exactly the one folded into the commitment: BlockCommit's commitment
        // equals the batch output hash computed with it, confirming independent commitment recomputability.
        Vm.Log memory blockCommitLog = _findUniqueLog(entries, BLOCK_COMMIT_TOPIC);
        assertEq(
            blockCommitLog.topics[3],
            _batchOutputHash(upgradeBatch, expectedUpgradeTxHash),
            "commitment folds in the reported upgrade tx hash"
        );
    }

    /// @notice A batch committed after the upgrade batch reports a zero upgrade transaction hash, even while the
    /// chain still holds the pending upgrade hash in storage (it is only cleared once the upgrade batch executes).
    function test_emitsZeroUpgradeTxHashForBatchAfterUpgradeBatch() public {
        _enableValidiumDA();

        bytes32 upgradeTxHash = Utils.randomBytes32("upgradeTx");
        utilsFacet.util_setL2SystemContractsUpgradeTxHash(upgradeTxHash);

        // Commit batch 1 as the upgrade batch; this records the upgrade batch number.
        CommitBatchInfoZKsyncOS memory upgradeBatch = _validiumBatch(1);
        _commitRecordingLogs(genesisStoredBatchInfo, upgradeBatch);
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 1, "batch 1 recorded as upgrade batch");

        // Commit batch 2 on top of batch 1. The pending upgrade hash is still in storage, but because the upgrade
        // batch already happened the new batch must report a zero upgrade tx hash.
        CommitBatchInfoZKsyncOS memory nextBatch = _validiumBatch(2);
        IExecutor.StoredBatchInfo memory storedBatch1 = _storedBatchInfo(upgradeBatch, upgradeTxHash);
        Vm.Log[] memory entries = _commitRecordingLogs(storedBatch1, nextBatch);

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(log.emitter, address(committer), "event emitted by the chain diamond");
        assertEq(log.topics[1], bytes32(uint256(2)), "batchNumber 2");
        assertEq(log.topics[3], bytes32(0), "no upgrade tx hash for a batch after the upgrade batch");
    }
}
