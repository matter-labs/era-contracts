// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {EVENT_INDEX, L2_DA_COMMITMENT_SCHEME, L2_SYSTEM_CONTEXT_ADDRESS, Utils} from "../../Utils/Utils.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";

import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, POINT_EVALUATION_PRECOMPILE_ADDR, TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {IExecutor, SystemLogKey, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {IL2GenesisUpgrade} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract RevertBatchesTest is ChainTypeManagerTest {
    // Items for logs & commits
    uint256 internal currentTimestamp;
    CommitBatchInfo internal newCommitBatchInfo;
    IExecutor.StoredBatchInfo internal newStoredBatchInfo;
    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    uint256[] internal proofInput;
    bytes32 l2DAValidatorOutputHash;
    bytes operatorDAInput;
    bytes defaultBlobCommitment;
    bytes32[] defaultBlobVersionedHashes;
    bytes16 defaultBlobOpeningPoint = 0x7142c5851421a2dc03dde0aabdb0ffdb;
    bytes32 defaultBlobClaimedValue = 0x1e5eea3bbb85517461c1d1c7b84c7c2cec050662a5e81a71d5d7e2766eaff2f0;
    bytes l2Logs;
    address newChainAddress;

    bytes32 constant EMPTY_PREPUBLISHED_COMMITMENT = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes constant POINT_EVALUATION_PRECOMPILE_RESULT =
        hex"000000000000000000000000000000000000000000000000000000000000100073eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001";

    // Facets exposing the diamond
    AdminFacet internal adminFacet;
    ExecutorFacet internal executorFacet;
    CommitterFacet internal committerFacet;
    GettersFacet internal gettersFacet;

    function setUp() public {
        deploy();

        defaultBlobCommitment = Utils.getDefaultBlobCommitment();
        defaultBlobVersionedHashes = new bytes32[](1);
        defaultBlobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(defaultBlobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);

        l2Logs = Utils.encodePacked(Utils.createSystemLogs(bytes32(0)));
        genesisStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: bytes32(uint256(0x01)),
            indexRepeatedStorageChanges: 0x01,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: 0,
            commitment: bytes32(uint256(0x01))
        });
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1 + 1);
        currentTimestamp = block.timestamp;
        newCommitBatchInfo = CommitBatchInfo({
            batchNumber: 1,
            timestamp: uint64(currentTimestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            bootloaderHeapInitialContentsHash: Utils.randomBytes32("bootloaderHeapInitialContentsHash"),
            eventsQueueStateHash: Utils.randomBytes32("eventsQueueStateHash"),
            systemLogs: l2Logs,
            operatorDAInput: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        {
            bytes memory complexUpgraderCalldata;
            address l1CtmDeployer = address(bridgehub.l1CtmDeployer());
            {
                bytes memory l2GenesisUpgradeCalldata = abi.encodeCall(
                    IL2GenesisUpgrade.genesisUpgrade,
                    (false, chainId, l1CtmDeployer, forceDeploymentsData, "0x")
                );
                complexUpgraderCalldata = abi.encodeCall(
                    IComplexUpgrader.upgrade,
                    (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
                );
            }

            // slither-disable-next-line unused-return
            (, uint32 minorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(0));
        }

        mockDiamondInitInteropCenterCallsWithAddress(address(bridgehub), sharedBridge, baseTokenAssetId);

        newChainAddress = createNewChain(getDiamondCutData(diamondInit));
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector),
            abi.encode(newChainAddress)
        );

        executorFacet = ExecutorFacet(address(newChainAddress));
        committerFacet = CommitterFacet(address(newChainAddress));
        gettersFacet = GettersFacet(address(newChainAddress));
        adminFacet = AdminFacet(address(newChainAddress));

        vm.stopPrank();
        vm.prank(newChainAdmin);
        adminFacet.setDAValidatorPair(address(rollupL1DAValidator), L2_DA_COMMITMENT_SCHEME);
    }

    function test_SuccessfulBatchReverting() public {
        vm.startPrank(governor);

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

        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;
        bytes32 expectedSystemContractUpgradeTxHash = gettersFacet.getL2SystemContractsUpgradeTxHash();
        bytes[] memory correctL2Logs = Utils.createSystemLogsWithUpgradeTransactionForCTM(
            expectedSystemContractUpgradeTxHash,
            l2DAValidatorOutputHash
        );
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.timestamp = uint64(currentTimestamp);
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobHashes[0] = blobsLinearHashes[0];

        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobCommitments[0] = keccak256(
            abi.encodePacked(
                defaultBlobVersionedHashes[0],
                abi.encodePacked(defaultBlobOpeningPoint, defaultBlobClaimedValue)
            )
        );

        bytes32 expectedBatchCommitment = Utils.createBatchCommitment(
            correctNewCommitBatchInfo,
            uncompressedStateDiffHash,
            blobCommitments,
            blobHashes
        );

        CommitBatchInfo[] memory correctCommitBatchInfoArray = new CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.stopPrank();
        vm.startPrank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        committerFacet.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1 + EVENT_INDEX);
        assertEq(entries[EVENT_INDEX].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[EVENT_INDEX].topics[1], bytes32(uint256(1))); // batchNumber
        assertEq(entries[EVENT_INDEX].topics[2], correctNewCommitBatchInfo.newStateRoot); // batchHash

        uint256 totalBatchesCommitted = gettersFacet.getTotalBatchesCommitted();
        assertEq(totalBatchesCommitted, 1);

        newStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 1,
            batchHash: entries[EVENT_INDEX].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: currentTimestamp,
            commitment: entries[EVENT_INDEX].topics[3]
        });

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );

        executorFacet.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);

        // Test batch revert triggered from CTM
        vm.stopPrank();
        vm.prank(address(chainContractAddress));
        adminFacet.setValidator(address(chainContractAddress), true);
        vm.startPrank(governor);

        uint256 totalBlocksCommittedBefore = gettersFacet.getTotalBlocksCommitted();
        assertEq(totalBlocksCommittedBefore, 1, "totalBlocksCommittedBefore");

        uint256 totalBlocksVerifiedBefore = gettersFacet.getTotalBlocksVerified();
        assertEq(totalBlocksVerifiedBefore, 1, "totalBlocksVerifiedBefore");

        chainContractAddress.revertBatches(chainId, 0);

        uint256 totalBlocksCommitted = gettersFacet.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 0, "totalBlocksCommitted");

        uint256 totalBlocksVerified = gettersFacet.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 0, "totalBlocksVerified");
    }
}
