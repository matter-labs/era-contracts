// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";
import {ExecutorTest, EMPTY_PREPUBLISHED_COMMITMENT, POINT_EVALUATION_PRECOMPILE_RESULT} from "../Executor/_Executor_Shared.t.sol";
import {Utils, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";
import {IExecutor, SystemLogKey, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";

contract PermissionlessValidatorExecutorIntegrationTest is ExecutorTest {
    PermissionlessValidator internal permissionlessValidator;
    bytes32[] internal defaultBlobVersionedHashes;
    bytes internal operatorDAInput;
    bytes32 internal l2DAValidatorOutputHash;

    function setUp() public {
        permissionlessValidator = new PermissionlessValidator();
        vm.prank(getters.getChainTypeManager());
        admin.setValidator(address(permissionlessValidator), true);

        bytes1 source = 0x01;
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
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        l2DAValidatorOutputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes
        );

        defaultBlobVersionedHashes = new bytes32[](1);
        defaultBlobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(defaultBlobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);
    }

    function test_settleBatchesSharedBridge_withExecutor() public {
        IExecutor.CommitBatchInfo memory commitInfo = _buildCommitInfo();

        IExecutor.CommitBatchInfo[] memory commitInfos = new IExecutor.CommitBatchInfo[](1);
        commitInfos[0] = commitInfo;

        vm.blobhashes(defaultBlobVersionedHashes);
        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            commitInfos
        );

        IExecutor.StoredBatchInfo memory storedInfo = _buildStoredBatchInfo(commitInfo);
        IExecutor.StoredBatchInfo[] memory storedArray = new IExecutor.StoredBatchInfo[](1);
        storedArray[0] = storedInfo;

        (uint256 proveFrom, uint256 proveTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedArray,
            proofInput
        );

        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](1);
        priorityOps[0] = PriorityOpsBatchInfo({
            leftPath: new bytes32[](0),
            rightPath: new bytes32[](0),
            itemHashes: new bytes32[](0)
        });

        (uint256 executeFrom, uint256 executeTo, bytes memory executeData) = Utils.encodeExecuteBatchesDataZeroLogs(
            storedArray,
            priorityOps
        );

        assertEq(commitFrom, proveFrom);
        assertEq(commitFrom, executeFrom);
        assertEq(commitTo, proveTo);
        assertEq(commitTo, executeTo);

        vm.blobhashes(defaultBlobVersionedHashes);
        permissionlessValidator.settleBatchesSharedBridge(
            address(executor),
            commitFrom,
            commitTo,
            commitData,
            proveData,
            executeData
        );

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 1);
        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(getters.l2LogsRootHash(1), storedInfo.l2LogsTreeRoot);
    }

    function _buildCommitInfo() internal returns (IExecutor.CommitBatchInfo memory) {
        IExecutor.CommitBatchInfo memory info = newCommitBatchInfo;
        bytes[] memory logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        info.systemLogs = Utils.encodePacked(logs);
        info.operatorDAInput = operatorDAInput;
        return info;
    }

    function _buildStoredBatchInfo(
        IExecutor.CommitBatchInfo memory commitInfo
    ) internal returns (IExecutor.StoredBatchInfo memory) {
        vm.blobhashes(defaultBlobVersionedHashes);
        L1DAValidatorOutput memory daOutput = IL1DAValidator(rollupL1DAValidator).checkDA({
            _chainId: l2ChainId,
            _batchNumber: commitInfo.batchNumber,
            _l2DAValidatorOutputHash: l2DAValidatorOutputHash,
            _operatorDAInput: commitInfo.operatorDAInput,
            _maxBlobsSupported: TOTAL_BLOBS_IN_COMMITMENT
        });

        bytes32 commitment = Utils.createBatchCommitment(
            commitInfo,
            daOutput.stateDiffHash,
            daOutput.blobsOpeningCommitments,
            daOutput.blobsLinearHashes
        );

        return
            IExecutor.StoredBatchInfo({
                batchNumber: commitInfo.batchNumber,
                batchHash: commitInfo.newStateRoot,
                indexRepeatedStorageChanges: commitInfo.indexRepeatedStorageChanges,
                numberOfLayer1Txs: commitInfo.numberOfLayer1Txs,
                priorityOperationsHash: commitInfo.priorityOperationsHash,
                dependencyRootsRollingHash: bytes32(0),
                l2LogsTreeRoot: bytes32(0),
                timestamp: commitInfo.timestamp,
                commitment: commitment
            });
    }
}
