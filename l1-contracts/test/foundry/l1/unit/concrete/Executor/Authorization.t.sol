// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Utils} from "../Utils/Utils.sol";

import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

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
            operatorDAInput: bytes("")
        });
    }

    function test_RevertWhen_CommittingByUnauthorisedAddress() public {
        IExecutor.CommitBatchInfo[] memory commitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        commitBatchInfoArray[0] = commitBatchInfo;

        vm.prank(randomSigner);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatchInfo,
            commitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_ProvingByUnauthorisedAddress() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = storedBatchInfo;

        vm.prank(owner);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            storedBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(uint256(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_ExecutingByUnauthorizedAddress() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = storedBatchInfo;

        vm.prank(randomSigner);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.emptyData()
        );
        executor.executeBatchesSharedBridge(uint256(0), executeBatchFrom, executeBatchTo, executeData);
    }
}
