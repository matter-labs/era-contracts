// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {Utils, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";
import {UtilsFacet} from "../Utils/UtilsFacet.sol";
import {
    EMPTY_PREPUBLISHED_COMMITMENT,
    ExecutorTest,
    POINT_EVALUATION_PRECOMPILE_RESULT
} from "./_Executor_Shared.t.sol";

import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @dev topic0 hashes of the commit-path events asserted in these tests. They are derived from the canonical event
/// signatures declared in ICommitter.sol and kept as keccak literals to mirror the event-assertion style in
/// Committing.t.sol.
bytes32 constant REPORT_PROTOCOL_VERSION_TOPIC = keccak256(
    "ReportCommittedBatchProtocolVersion(uint64,uint256,bytes32)"
);
bytes32 constant BLOCK_COMMIT_TOPIC = keccak256("BlockCommit(uint256,bytes32,bytes32)");
bytes32 constant REPORT_BATCH_RANGE_TOPIC = keccak256("ReportCommittedBatchRangeZKsyncOS(uint64,uint64,uint64)");

/// @notice Shared helpers for asserting the `ReportCommittedBatchProtocolVersion` event on the Era (EraVM) commit
/// path. The feature makes the protocol version and the upgrade transaction hash of every committed batch
/// determinable from on-chain data alone; this file is the Era counterpart of CommittingProtocolVersionZKsyncOS.t.sol.
/// @dev `isZKsyncOS()` is left at its default `false`, so the chain commits via the Era path.
abstract contract CommitProtocolVersionEraBase is ExecutorTest {
    bytes32[] internal defaultBlobVersionedHashes;
    bytes32 internal l2DAValidatorOutputHash;
    bytes internal operatorDAInput;

    /// @dev Configures a single-blob rollup DA input + the point-evaluation precompile mock, mirroring the setup in
    /// Committing.t.sol so a real Era commit succeeds.
    function _setUpBlobDA() internal {
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            bytes1(0x01),
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );
        l2DAValidatorOutputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        defaultBlobVersionedHashes = new bytes32[](1);
        defaultBlobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(defaultBlobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);
    }

    /// @dev Builds the system logs for a normal (non-upgrade) Era batch with the correct DA output hash + timestamp.
    function _eraSystemLogs() internal returns (bytes[] memory logs) {
        logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
    }

    /// @dev Same as `_eraSystemLogs`, plus the expected system-contract upgrade tx hash log required for the first
    /// batch committed after a protocol upgrade.
    function _eraSystemLogsWithUpgrade(bytes32 _upgradeTxHash) internal returns (bytes[] memory logs) {
        bytes[] memory base = _eraSystemLogs();
        logs = new bytes[](base.length + 1);
        for (uint256 i = 0; i < base.length; ++i) {
            logs[i] = base[i];
        }
        logs[base.length] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY),
            _upgradeTxHash
        );
    }

    /// @dev Commits a single Era batch (built from `newCommitBatchInfo` with the given system logs) as the validator
    /// while recording the emitted logs.
    function _commitEraRecordingLogs(bytes[] memory _logs) internal returns (Vm.Log[] memory entries) {
        CommitBatchInfo memory info = newCommitBatchInfo;
        info.systemLogs = Utils.encodePacked(_logs);
        info.operatorDAInput = operatorDAInput;

        CommitBatchInfo[] memory batchArray = new CommitBatchInfo[](1);
        batchArray[0] = info;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            batchArray
        );
        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);
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

    /// @dev True if any recorded log has topic0 equal to `_topic0`.
    function _hasLog(Vm.Log[] memory _entries, bytes32 _topic0) internal pure returns (bool) {
        for (uint256 i = 0; i < _entries.length; ++i) {
            if (_entries[i].topics.length != 0 && _entries[i].topics[0] == _topic0) {
                return true;
            }
        }
        return false;
    }
}

/// @notice Tests for the `ReportCommittedBatchProtocolVersion` event on the Era commit path that do not require
/// manipulating chain state (the default harness commits under protocol version 0 with no pending upgrade).
contract CommitProtocolVersionEraTest is CommitProtocolVersionEraBase {
    function setUp() public {
        _setUpBlobDA();
    }

    /// @notice A committed Era batch emits the protocol version it was committed with, and a zero upgrade
    /// transaction hash when there is no pending protocol upgrade.
    function test_emitsProtocolVersionWithZeroUpgradeTxHash() public {
        Vm.Log[] memory entries = _commitEraRecordingLogs(_eraSystemLogs());

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(log.emitter, address(committer), "event emitted by the chain diamond");
        assertEq(log.topics[1], bytes32(uint256(1)), "batchNumber");
        // The harness initializes the chain with protocol version 0.
        assertEq(log.topics[2], bytes32(uint256(0)), "protocolVersion equals the chain's protocol version");
        assertEq(log.topics[3], bytes32(0), "no upgrade tx hash for a non-upgrade batch");
    }

    /// @notice On the Era path the new event is emitted alongside BlockCommit, and the ZKsync-OS-only
    /// ReportCommittedBatchRangeZKsyncOS event is NOT emitted.
    function test_eventCoexistsWithBlockCommitAndIsEraOnly() public {
        Vm.Log[] memory entries = _commitEraRecordingLogs(_eraSystemLogs());

        Vm.Log memory protocolVersionLog = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        Vm.Log memory blockCommitLog = _findUniqueLog(entries, BLOCK_COMMIT_TOPIC);

        assertEq(protocolVersionLog.topics[1], bytes32(uint256(1)), "protocol version event batchNumber");
        assertEq(blockCommitLog.topics[1], bytes32(uint256(1)), "BlockCommit batchNumber");
        assertFalse(_hasLog(entries, REPORT_BATCH_RANGE_TOPIC), "ZKsync OS range event must not fire on Era");
    }
}

/// @notice Tests that drive non-default protocol versions and a protocol upgrade through real diamond calls (via
/// UtilsFacet) and the real Era upgrade-commit flow, instead of storage-slot overrides.
contract CommitProtocolVersionEraWithUtilsTest is CommitProtocolVersionEraBase {
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

    function setUp() public {
        _setUpBlobDA();
    }

    /// @notice The emitted protocol version equals the chain's protocol version at commit time, so it stays correct
    /// for a batch even if later upgrades change the chain's current protocol version.
    function test_emittedProtocolVersionReflectsConfiguredVersion() public {
        // A semver-like packed value (minor = 27, patch = 7); any non-zero value demonstrates the point.
        uint256 configuredProtocolVersion = (uint256(27) << 32) | uint256(7);
        utilsFacet.util_setProtocolVersion(configuredProtocolVersion);
        assertEq(utilsFacet.util_getProtocolVersion(), configuredProtocolVersion, "protocol version set");

        Vm.Log[] memory entries = _commitEraRecordingLogs(_eraSystemLogs());

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(
            log.topics[2],
            bytes32(configuredProtocolVersion),
            "emitted protocol version must equal the version used to commit the batch"
        );
        assertEq(log.topics[3], bytes32(0), "no upgrade tx hash for a non-upgrade batch");
    }

    /// @notice For the first Era batch committed after a protocol upgrade, the event reports the upgrade transaction
    /// hash. The Era upgrade-commit flow additionally requires the matching expected-upgrade-tx-hash system log.
    function test_emitsUpgradeTxHashForUpgradeBatch() public {
        bytes32 expectedUpgradeTxHash = Utils.randomBytes32("upgradeTx");
        // Simulate a pending protocol upgrade whose upgrade batch has not been committed yet.
        utilsFacet.util_setL2SystemContractsUpgradeTxHash(expectedUpgradeTxHash);
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 0, "no upgrade batch recorded yet");

        Vm.Log[] memory entries = _commitEraRecordingLogs(_eraSystemLogsWithUpgrade(expectedUpgradeTxHash));

        Vm.Log memory log = _findUniqueLog(entries, REPORT_PROTOCOL_VERSION_TOPIC);
        assertEq(log.topics[1], bytes32(uint256(1)), "batchNumber");
        assertEq(log.topics[3], expectedUpgradeTxHash, "upgrade tx hash reported for the upgrade batch");

        // The commit must record this batch as the upgrade batch, mirroring _commitBatchesSharedBridgeEra.
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 1, "upgrade batch number recorded");
    }
}
