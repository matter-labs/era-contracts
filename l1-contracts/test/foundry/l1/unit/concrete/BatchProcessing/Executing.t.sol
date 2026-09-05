// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, Vm, stdStorage} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";

import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    BatchHashMismatch,
    CantExecuteUnprovenBatches,
    NonSequentialBatch,
    PriorityOperationsRollingHashMismatch,
    QueueIsEmpty
} from "contracts/common/L1ContractErrors.sol";
import {PriorityOpsBatchInfo, PriorityTree} from "contracts/state-transition/libraries/PriorityTree.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

contract ExecutingTest is ExecutorTest {
    using stdStorage for StdStorage;

    bytes32[] priorityOpsHashes;
    bytes32 correctRollingHash;

    function appendPriorityOps() internal {
        for (uint256 i = 0; i < priorityOpsHashes.length; i++) {
            executor.appendPriorityOp(priorityOpsHashes[i]);
        }
    }

    function generatePriorityOps(uint256 priorityOpsLength) internal {
        bytes32[] memory hashes = new bytes32[](priorityOpsLength);
        for (uint256 i = 0; i < priorityOpsLength; ++i) {
            hashes[i] = keccak256(abi.encodePacked("hash", i));
        }

        bytes32 rollingHash = keccak256("");

        for (uint256 i = 0; i < hashes.length; i++) {
            rollingHash = keccak256(bytes.concat(rollingHash, hashes[i]));
        }

        correctRollingHash = rollingHash;
        priorityOpsHashes = hashes;
    }

    function getV31UpgradeChainBatchNumberLocation(bytes32 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainId, uint256(11)));
    }

    function setUp() public {
        generatePriorityOps(2);

        // This currently only uses the legacy priority queue, not the priority tree.
        executor.setPriorityTreeStartIndex(1);
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        CommitBatchInfoZKsyncOS memory commitInfo = newCommitBatchInfoZKsyncOS;
        commitInfo.firstBlockTimestamp = uint64(currentTimestamp);
        commitInfo.lastBlockTimestamp = uint64(currentTimestamp);
        commitInfo.priorityOperationsHash = correctRollingHash;
        commitInfo.numberOfLayer1Txs = priorityOpsHashes.length;
        // The execute-path fixtures carry no dependency interop roots, so the committed rolling
        // hash must be the empty (zero) one.
        commitInfo.dependencyRootsRollingHash = bytes32(0);

        newStoredBatchInfo = _commitOSBatchGetStored(genesisStoredBatchInfo, commitInfo);

        /// These constants were the hashes that are needed for the test to run. PriorityTree hashing validity is checked separately.
        executor.setPriorityTreeHistoricalRoot(0x682709a1fd539b1a69dfd64ade8d17231d5498c372fb8a6325ec545137f8a35a);
        executor.setPriorityTreeHistoricalRoot(0xa09200c9b365ebf37db651d6096b20c46ea62ff692839090fb0494a53ee80b28);
        executor.setPriorityTreeHistoricalRoot(0x500f38f9d51b79071e5020b1c196f90fb3fc2fd089eb9358f205b523953d2985);

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_ExecutingBlockWithWrongBatchNumber() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.batchNumber = 10; // Correct is 1

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = wrongNewStoredBatchInfo;

        vm.prank(validator);
        vm.expectRevert(NonSequentialBatch.selector);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRootBase.addChainBatchRootV32.selector, 9, 10, bytes32(0)),
            abi.encode()
        );

        vm.store(address(messageRoot), getV31UpgradeChainBatchNumberLocation(bytes32(l2ChainId)), bytes32(uint256(1)));
        executor.executeBatchesSharedBridge(address(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingBlockWithWrongData() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.timestamp = 1; // incorrect: ZKsync OS stored batches carry timestamp 0

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = wrongNewStoredBatchInfo;

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(newStoredBatchInfo)),
                keccak256(abi.encode(wrongNewStoredBatchInfo))
            )
        );
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(address(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingRevertedBlockWithoutCommittingAndProvingAgain() public {
        appendPriorityOps();

        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        vm.expectRevert(CantExecuteUnprovenBatches.selector);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(address(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingUnavailablePriorityOperationHash() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);
        generatePriorityOps(1);

        CommitBatchInfoZKsyncOS memory commitInfo = newCommitBatchInfoZKsyncOS;
        commitInfo.priorityOperationsHash = correctRollingHash;
        commitInfo.numberOfLayer1Txs = 1;
        commitInfo.dependencyRootsRollingHash = bytes32(0);

        IExecutor.StoredBatchInfo memory correctNewStoredBatchInfo = _commitOSBatchGetStored(
            genesisStoredBatchInfo,
            commitInfo
        );

        IExecutor.StoredBatchInfo[] memory correctNewStoredBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        correctNewStoredBatchInfoArray[0] = correctNewStoredBatchInfo;

        vm.prank(validator);
        uint256 processBatchFrom;
        uint256 processBatchTo;
        bytes memory processData;
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeProveBatchesData(
                genesisStoredBatchInfo,
                correctNewStoredBatchInfoArray,
                proofInput
            );
            executor.proveBatchesSharedBridge(address(0), processBatchFrom, processBatchTo, processData);
        }

        vm.prank(validator);
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeExecuteBatchesData(
                correctNewStoredBatchInfoArray,
                Utils.generatePriorityOps(correctNewStoredBatchInfoArray.length, 1)
            );
            executor.executeBatchesSharedBridge(address(0), processBatchFrom, processBatchTo, processData);
        }
    }

    function test_RevertWhen_ExecutingWithUnmatchedPriorityOperationHash() public {
        appendPriorityOps();

        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);
        /// 3 priority operations to generate error
        generatePriorityOps(3);

        CommitBatchInfoZKsyncOS memory commitInfo = newCommitBatchInfoZKsyncOS;
        commitInfo.priorityOperationsHash = correctRollingHash;
        commitInfo.numberOfLayer1Txs = 2;
        commitInfo.dependencyRootsRollingHash = bytes32(0);

        IExecutor.StoredBatchInfo memory correctNewStoredBatchInfo = _commitOSBatchGetStored(
            genesisStoredBatchInfo,
            commitInfo
        );

        IExecutor.StoredBatchInfo[] memory correctNewStoredBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        correctNewStoredBatchInfoArray[0] = correctNewStoredBatchInfo;

        vm.prank(validator);
        uint256 processBatchFrom;
        uint256 processBatchTo;
        bytes memory processData;
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeProveBatchesData(
                genesisStoredBatchInfo,
                correctNewStoredBatchInfoArray,
                proofInput
            );
            executor.proveBatchesSharedBridge(address(0), processBatchFrom, processBatchTo, processData);
        }

        bytes32 randomFactoryDeps0 = Utils.randomBytes32("randomFactoryDeps0");

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps0);

        uint256 gasPrice = 1000000000;
        uint256 l2GasLimit = 1000000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        uint256 l2Value = 10 ether;
        uint256 totalCost = baseCost + l2Value;

        dummyBridgehub.requestL2TransactionDirect{value: totalCost}(
            L2TransactionRequestDirect({
                chainId: l2ChainId,
                mintValue: totalCost,
                l2Contract: address(0),
                l2Value: l2Value,
                l2Calldata: bytes(""),
                l2GasLimit: l2GasLimit,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: factoryDeps,
                refundRecipient: address(0)
            })
        );

        vm.prank(validator);
        vm.expectRevert(PriorityOperationsRollingHashMismatch.selector);

        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeExecuteBatchesData(
                correctNewStoredBatchInfoArray,
                Utils.generatePriorityOps(correctNewStoredBatchInfoArray.length, 2)
            );
            executor.executeBatchesSharedBridge(address(0), processBatchFrom, processBatchTo, processData);
        }
    }

    function test_RevertWhen_CommittingBlockWithWrongPreviousBatchHash() public {
        appendPriorityOps();

        CommitBatchInfoZKsyncOS[] memory commitInfos = new CommitBatchInfoZKsyncOS[](1);
        commitInfos[0] = newCommitBatchInfoZKsyncOS;

        bytes32 wrongPreviousBatchHash = Utils.randomBytes32("wrongPreviousBatchHash");

        IExecutor.StoredBatchInfo memory genesisBlock = genesisStoredBatchInfo;
        genesisBlock.batchHash = wrongPreviousBatchHash;

        bytes32 storedBatchHash = getters.storedBlockHash(1);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(BatchHashMismatch.selector, storedBatchHash, keccak256(abi.encode(genesisBlock)))
        );
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisBlock, commitInfos);
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_ShouldExecuteBatchesSuccessfully() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(address(0), executeBatchFrom, executeBatchTo, executeData);

        uint256 totalBlocksExecuted = getters.getTotalBlocksExecuted();
        assertEq(totalBlocksExecuted, 1);

        bool isPriorityQueueActive = getters.isPriorityQueueActive();
        assert(isPriorityQueueActive);

        uint256 processed = getters.getFirstUnprocessedPriorityTx();
        assertEq(processed, 3);
    }

    // For accurate measuring of gas usage via snapshot cheatcodes, isolation mode has to be enabled.
    /// forge-config: default.isolate = true
    function test_MeasureGas() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        validatorTimelock.executeBatchesSharedBridge(address(executor), executeBatchFrom, executeBatchTo, executeData);
        vm.snapshotGasLastCall("Executor", "execute");
    }
}
