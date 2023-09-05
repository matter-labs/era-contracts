// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./_Executor_Shared.t.sol";

contract AuthorizationTest is ExecutorTest {
    IExecutor.StoredBlockInfo storedBlockInfo;
    IExecutor.CommitBlockInfo commitBlockInfo;

    function setUp() public {
        storedBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: keccak256(bytes.concat("randomBytes32", "setUp()", "0")),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "1")
            ),
            timestamp: 0,
            commitment: keccak256(bytes.concat("randomBytes32", "setUp()", "2"))
        });

        commitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 0,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "3")
            ),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "4")
            ),
            priorityOperationsHash: keccak256(""),
            initialStorageChanges: bytes(""),
            repeatedStorageChanges: bytes(""),
            l2Logs: bytes(""),
            l2ArbitraryLengthMessages: new bytes[](0),
            factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_CommitingByUnauthorisedAddress() public {
        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = commitBlockInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.commitBlocks(storedBlockInfo, commitBlockInfoArray);
    }

    function test_RevertWhen_ProvingByUnauthorisedAddress() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = storedBlockInfo;

        vm.prank(owner);

        vm.expectRevert(bytes.concat("1h"));
        executor.proveBlocks(storedBlockInfo, storedBlockInfoArray, proofInput);
    }

    function test_RevertWhen_ExecutingByUnauthorizedAddress() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = storedBlockInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.executeBlocks(storedBlockInfoArray);
    }
}
