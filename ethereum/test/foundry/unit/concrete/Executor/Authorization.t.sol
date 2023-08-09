// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IExecutor} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IExecutor.sol";

contract AuthorizationTest is ExecutorTest {
    IExecutor.StoredBlockInfo private storedBlockInfo;
    IExecutor.CommitBlockInfo private commitBlockInfo;

    function setUp() public {
        storedBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: Utils.randomBytes32("blockHash"),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: Utils.randomBytes32("l2LogsTreeRoot"),
            timestamp: 0,
            commitment: Utils.randomBytes32("commitment")
        });

        commitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 0,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: Utils.randomBytes32("l2LogsTreeRoot"),
            priorityOperationsHash: keccak256(""),
            initialStorageChanges: bytes(""),
            repeatedStorageChanges: bytes(""),
            l2Logs: bytes(""),
            l2ArbitraryLengthMessages: new bytes[](0),
            factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_CommitingByUnauthorisedAddress() public {
        IExecutor.CommitBlockInfo[] memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = commitBlockInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.commitBlocks(storedBlockInfo, commitBlockInfoArray);
    }

    function test_RevertWhen_ProvingByUnauthorisedAddress() public {
        IExecutor.StoredBlockInfo[] memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = storedBlockInfo;

        vm.prank(owner);

        vm.expectRevert(bytes.concat("1h"));
        executor.proveBlocks(storedBlockInfo, storedBlockInfoArray, proofInput);
    }

    function test_RevertWhen_ExecutingByUnauthorizedAddress() public {
        IExecutor.StoredBlockInfo[] memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = storedBlockInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.executeBlocks(storedBlockInfoArray);
    }
}
