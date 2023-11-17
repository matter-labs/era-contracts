// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IExecutor} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IExecutor.sol";

contract AuthorizationTest is ExecutorTest {
    IExecutor.StoredBatchInfo private storedBatchInfo;
    IExecutor.CommitBatchInfo private commitBatchInfo;

    function setUp() public {
        storedBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: Utils.randomBytes32("batchHash"),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: Utils.randomBytes32("priorityOperationsHash"),
            l2LogsTreeRoot: Utils.randomBytes32("l2LogsTreeRoot"),
            timestamp: 0,
            commitment: Utils.randomBytes32("commitment")
        });

        commitBatchInfo = IExecutor.CommitBatchInfo({
            batchNumber: 0,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: Utils.randomBytes32("priorityOperationsHash"),
            bootloaderHeapInitialContentsHash: Utils.randomBytes32("bootloaderHeapInitialContentsHash"),
            eventsQueueStateHash: Utils.randomBytes32("eventsQueueStateHash"),
            systemLogs: bytes(""),
            totalL2ToL1Pubdata: bytes("")
        });
    }

    function test_RevertWhen_CommitingByUnauthorisedAddress() public {
        IExecutor.CommitBatchInfo[] memory commitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        commitBatchInfoArray[0] = commitBatchInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.commitBatches(storedBatchInfo, commitBatchInfoArray);
    }

    function test_RevertWhen_ProvingByUnauthorisedAddress() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = storedBatchInfo;

        vm.prank(owner);

        vm.expectRevert(bytes.concat("1h"));
        executor.proveBatches(storedBatchInfo, storedBatchInfoArray, proofInput);
    }

    function test_RevertWhen_ExecutingByUnauthorizedAddress() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = storedBatchInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.executeBatches(storedBatchInfoArray);
    }
}
