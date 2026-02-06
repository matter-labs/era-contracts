// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, Vm, stdStorage} from "forge-std/Test.sol";
import {EVENT_INDEX, L2_SYSTEM_CONTEXT_ADDRESS, Utils} from "../Utils/Utils.sol";

import {EMPTY_PREPUBLISHED_COMMITMENT, ExecutorTest, POINT_EVALUATION_PRECOMPILE_RESULT} from "./_Executor_Shared.t.sol";

import {POINT_EVALUATION_PRECOMPILE_ADDR, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {BatchHashMismatch, CantExecuteUnprovenBatches, NonSequentialBatch, PriorityOperationsRollingHashMismatch, QueueIsEmpty} from "contracts/common/L1ContractErrors.sol";
import {PriorityOpsBatchInfo, PriorityTree} from "contracts/state-transition/libraries/PriorityTree.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";

contract ExecutingTest is ExecutorTest {
    using stdStorage for StdStorage;

    bytes32 l2DAValidatorOutputHash;
    bytes32[] blobVersionedHashes;

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

        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
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
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        blobVersionedHashes = new bytes32[](1);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(blobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);

        // This currently only uses the legacy priority queue, not the priority tree.
        executor.setPriorityTreeStartIndex(1);
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        correctL2Logs[uint256(uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            correctRollingHash
        );
        correctL2Logs[uint256(uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(priorityOpsHashes.length)
        );

        bytes memory l2Logs = Utils.encodePacked(correctL2Logs);

        newCommitBatchInfo.systemLogs = l2Logs;
        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.operatorDAInput = operatorDAInput;
        newCommitBatchInfo.priorityOperationsHash = correctRollingHash;
        newCommitBatchInfo.numberOfLayer1Txs = priorityOpsHashes.length;

        CommitBatchInfo[] memory commitBatchInfoArray = new CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            commitBatchInfoArray
        );
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
        /// These constants were the hashes that are needed for the test to run. PriorityTree hashing validity is checked separately.
        executor.setPriorityTreeHistoricalRoot(0x682709a1fd539b1a69dfd64ade8d17231d5498c372fb8a6325ec545137f8a35a);
        executor.setPriorityTreeHistoricalRoot(0xa09200c9b365ebf37db651d6096b20c46ea62ff692839090fb0494a53ee80b28);
        executor.setPriorityTreeHistoricalRoot(0x500f38f9d51b79071e5020b1c196f90fb3fc2fd089eb9358f205b523953d2985);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 1,
            batchHash: entries[EVENT_INDEX].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: priorityOpsHashes.length,
            priorityOperationsHash: correctRollingHash,
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[EVENT_INDEX].topics[3]
        });

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
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils
            .encodeExecuteBatchesDataZeroLogs(
                storedBatchInfoArray,
                Utils.generatePriorityOps(storedBatchInfoArray.length)
            );
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRoot.addChainBatchRoot.selector, 9, 10, bytes32(0)),
            abi.encode()
        );

        vm.store(address(messageRoot), getV31UpgradeChainBatchNumberLocation(bytes32(l2ChainId)), bytes32(uint256(1)));
        executor.executeBatchesSharedBridge(address(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingBlockWithWrongData() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.timestamp = 0; // incorrect timestamp

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
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils
            .encodeExecuteBatchesDataZeroLogs(
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
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils
            .encodeExecuteBatchesDataZeroLogs(
                storedBatchInfoArray,
                Utils.generatePriorityOps(storedBatchInfoArray.length)
            );
        executor.executeBatchesSharedBridge(address(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingUnavailablePriorityOperationHash() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);
        generatePriorityOps(1);

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        correctL2Logs[uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            correctRollingHash
        );
        correctL2Logs[uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(uint256(1))
        );

        CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.priorityOperationsHash = correctRollingHash;
        correctNewCommitBatchInfo.numberOfLayer1Txs = 1;

        CommitBatchInfo[] memory correctNewCommitBatchInfoArray = new CommitBatchInfo[](1);
        correctNewCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctNewCommitBatchInfoArray
        );
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBatchInfo memory correctNewStoredBatchInfo = newStoredBatchInfo;
        correctNewStoredBatchInfo.batchHash = entries[EVENT_INDEX].topics[2];
        correctNewStoredBatchInfo.numberOfLayer1Txs = 1;
        correctNewStoredBatchInfo.priorityOperationsHash = correctRollingHash;
        correctNewStoredBatchInfo.commitment = entries[EVENT_INDEX].topics[3];

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
        // vm.expectRevert(QueueIsEmpty.selector);
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeExecuteBatchesDataZeroLogs(
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

        bytes32 arbitraryCanonicalTxHash = Utils.randomBytes32("arbitraryCanonicalTxHash");
        bytes32 chainedPriorityTxHash = keccak256(bytes.concat(keccak256(""), arbitraryCanonicalTxHash));

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        correctL2Logs[uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            correctRollingHash
        );
        correctL2Logs[uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(uint256(2))
        );
        CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.priorityOperationsHash = correctRollingHash;
        correctNewCommitBatchInfo.numberOfLayer1Txs = 2;

        CommitBatchInfo[] memory correctNewCommitBatchInfoArray = new CommitBatchInfo[](1);
        correctNewCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctNewCommitBatchInfoArray
        );
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBatchInfo memory correctNewStoredBatchInfo = newStoredBatchInfo;
        correctNewStoredBatchInfo.batchHash = entries[EVENT_INDEX].topics[2];
        correctNewStoredBatchInfo.numberOfLayer1Txs = 2;
        correctNewStoredBatchInfo.priorityOperationsHash = correctRollingHash;
        correctNewStoredBatchInfo.commitment = entries[EVENT_INDEX].topics[3];

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

        mailbox.requestL2Transaction{value: totalCost}({
            _contractL2: address(0),
            _l2Value: l2Value,
            _calldata: bytes(""),
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: factoryDeps,
            _refundRecipient: address(0)
        });

        vm.prank(validator);
        vm.expectRevert(PriorityOperationsRollingHashMismatch.selector);

        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeExecuteBatchesDataZeroLogs(
                correctNewStoredBatchInfoArray,
                Utils.generatePriorityOps(correctNewStoredBatchInfoArray.length, 2)
            );
            executor.executeBatchesSharedBridge(address(0), processBatchFrom, processBatchTo, processData);
        }
    }

    function test_RevertWhen_CommittingBlockWithWrongPreviousBatchHash() public {
        appendPriorityOps();

        // solhint-disable-next-line func-named-parameters
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32("")
        );

        CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = correctL2Logs;

        CommitBatchInfo[] memory correctNewCommitBatchInfoArray = new CommitBatchInfo[](1);
        correctNewCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        bytes32 wrongPreviousBatchHash = Utils.randomBytes32("wrongPreviousBatchHash");

        IExecutor.StoredBatchInfo memory genesisBlock = genesisStoredBatchInfo;
        genesisBlock.batchHash = wrongPreviousBatchHash;

        bytes32 storedBatchHash = getters.storedBlockHash(1);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(BatchHashMismatch.selector, storedBatchHash, keccak256(abi.encode(genesisBlock)))
        );
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisBlock,
            correctNewCommitBatchInfoArray
        );
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_ShouldExecuteBatchesSuccessfully() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils
            .encodeExecuteBatchesDataZeroLogs(
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
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils
            .encodeExecuteBatchesDataZeroLogs(
                storedBatchInfoArray,
                Utils.generatePriorityOps(storedBatchInfoArray.length)
            );
        validatorTimelock.executeBatchesSharedBridge(address(executor), executeBatchFrom, executeBatchTo, executeData);
        vm.snapshotGasLastCall("Executor", "execute");
    }

    /// This test takes data from real execution and recomputes the dependency roots rolling hash.
    function test_logExecuteData() public {
        uint256 from = 6798;
        bytes
            memory data = hex"01000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000000000000000000000000000000000000000062000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000001a8ed62acaf39783208fcddaee684e5ca2b7693fbb5978af4bd7ddd81bcdc9c175f20000000000000000000000000000000000000000000000000000000000001d5d0000000000000000000000000000000000000000000000000000000000000002f6005bf5b16c8b491f81c6cb92f917a8d5c0e10bd5b689b16ac47fcdd1220dba3e877fdd7b3f9fa7adeaca0b88430160762b5587f2758efcd1529ab3f763de823c6edec289e5512922c72dbbd9c3ebed59efea54288623f12ac0afb1e990b2930000000000000000000000000000000000000000000000000000000068a053fa21aad8d32fd5881588f6bd644f621208e8bfc1459c1f791e62059b49630fd780000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000003e0000000000000000000000000000000000000000000000000000000000000000d88ad2594ee8b981d3ef5420ad5250ed9de1436d076721bbcb9a15e7b18ebb31a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e5ed16037fb652be5487cdb073056e0554e1e9c05fdc7da0950f01ced4172c1c0c465544d4708f3b545c61d29cef84640cdac305ffd09c9beaa19aca9fc6b2820000000000000000000000000000000000000000000000000000000000000000a05c8f714cd022cb5ac8d5629b9f95e2455b4ca712b309e72daf16b18f63ead400000000000000000000000000000000000000000000000000000000000000003c5b8adbf4175733f7900bbc6a0ef3563dd7cd559197a2e5db83a2210e8249d50000000000000000000000000000000000000000000000000000000000000000cedbc7e1c8c59d9200d4b8405aab5d8c861bcea996b682067305bba074020e2e49d3823456c36ff9d77facc2e5464b6d674ee4b6cb3cb5dc6c4db2f3f70d41f9000000000000000000000000000000000000000000000000000000000000000da414724b068c2c5667efd7e961bd2dbca337e29bc984b69320b0b11947dfe0a2000000000000000000000000000000000000000000000000000000000000000069b1b11c3655dd725a46f3bcfc4305c3022d8dd6ae6502190571a9b709a2a8e87388b7ae694d650f6347f3c593e33a95a91deeed22c74af1326c4d363823933b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c992ef0bdf73920fea3895cd7509b383e866f9ba569634617668279f44aca7e80000000000000000000000000000000000000000000000000000000000000000c75a4c92cc0306b976ea3d1c389f01eac5d786b3a2778027be39b027baea4ac800000000000000000000000000000000000000000000000000000000000000008460ccfbf1cf677570dc773f4d4b1dc6099a7243d2c296aaed6653800a38c171000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002212064ced811e7dd5b4d3406890595c4670cae0bfde889412a159e39ec5c72ff999ec81b5c8dbe6ea0f391758aac7fc247734dcc8aee54a85375cd48f42e5b080000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000032000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000460000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000005a0000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000006e00000000000000000000000000000000000000000000000000000000000000780000000000000000000000000000000000000000000000000000000000000082000000000000000000000000000000000000000000000000000000000000008c000000000000000000000000000000000000000000000000000000000000009600000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000aa00000000000000000000000000000000000000000000000000000000000000b400000000000000000000000000000000000000000000000000000000000000be00000000000000000000000000000000000000000000000000000000000000c800000000000000000000000000000000000000000000000000000000000000d200000000000000000000000000000000000000000000000000000000000000dc00000000000000000000000000000000000000000000000000000000000000e60000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f651000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000014fb886c527b4ab9848965f039693acd91b9c0b3bcbeab58989bb1df2be75da95000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f61c0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000192c801c7e325122d296d07d27c254ad37858a3358423d0401f38077f5a3aae4f000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f60200000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001602244f967799d0f74520b98c357d7d554118296c5ed31c6f7a6856df3fad066000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5fe000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000017de74f9b2bfee16d512c059dc07c405fd0bc79bfb13bb3b6dc67e517e93460a5000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5fa0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000114801f399a371ff59d38d7f78918ac277df43389073af074b37aac86cabd2338000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5f900000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001eabc2446af29d65ca3dc77afd5389015093298a78dc9d4efc9330e10c2e183ea000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5f700000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001ff7d87e25ade5a049177cac0c9a68821483780c005474ffaebc28ef6316cf618000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5ee000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000012c4110442b096562abff4741c2c96e8cae008048cc576daa5d76dc33cbd63dea000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5ed000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000019a53e2626e90094027acc7ecc75633d1abe736d5340deb0645f3ea14822d4cf2000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5ec00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001d7e03f2b5b0feb9dbe71659a71df2cabfeffe3f65eafec8c632b2c17d123a565000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5eb00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001d67c2d0cc8c0f1e1f5be8fda146b0d167397f18d139f38eb9da1b3eaf3414dea000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5ea0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000193f0b0b8c2ccabddc1c07cfaa996433d81223d91730d88fdad54804e305db8f9000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e8000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000012335ea8e9d4f0485ff8be5691160b03a5addbdfb8e02a3f7f080c3dcc19c9944000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e700000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001a6189e72789f643eec450a3e02b87d6931c7ed4bae9ac8181c79dc9352570274000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e6000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000015f08e0b445ec32b8bc3024359757af602777a7f1f79d3e2ec2838d5c2e13d704000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e500000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001f03bc20cf469641ef46dfcd8c0749e81d2dfa678781b0b59308ff1c29fb329d4000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e400000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001b508657ce12647ef390fa5c91834ab66e531fdb8dce356e36bbf717d3d94b696000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e2000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000013873ec57227b252e1257b289828722dcffa8245d5944102981e2870b5c7c00f8000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001672bebee9db3cad834b1534e6788e3a2d1fd239531caed5ea8a3ed1a6a1ab45a000000000000000000000000000000000000000000000000000000000000007b000000000000000000000000000000000000000000000000000000000001f5e000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001c9b13eea0113427a72a055767f015187ef3af07a18a84c2eacae887756f9219a";

        // (
        //     IExecutor.StoredBatchInfo[] memory batchesData,
        //     PriorityOpsBatchInfo[] memory priorityOpsData,
        //     InteropRoot[][] memory dependencyRoots
        // ) = this.decode(data, from);
        // bytes32 dependencyRootsRollingHash = 0;

        // for (uint256 i = 0; i < dependencyRoots[0].length; ++i) {
        //     InteropRoot memory interopRoot = dependencyRoots[0][i];

        //     dependencyRootsRollingHash = keccak256(
        //         // solhint-disable-next-line func-named-parameters
        //         abi.encodePacked(
        //             dependencyRootsRollingHash,
        //             interopRoot.chainId,
        //             interopRoot.blockOrBatchNumber,
        //             interopRoot.sides
        //         )
        //     );
        // }

        // InteropRoot[] memory dependencyRootsReordered = new InteropRoot[](dependencyRoots[0].length);
        // uint256 i = 0;

        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x602244f967799d0f74520b98c357d7d554118296c5ed31c6f7a6856df3fad066;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128514 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x7de74f9b2bfee16d512c059dc07c405fd0bc79bfb13bb3b6dc67e517e93460a5;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128510 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x14801f399a371ff59d38d7f78918ac277df43389073af074b37aac86cabd2338;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128506 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xeabc2446af29d65ca3dc77afd5389015093298a78dc9d4efc9330e10c2e183ea;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128505 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xff7d87e25ade5a049177cac0c9a68821483780c005474ffaebc28ef6316cf618;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128503 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x2c4110442b096562abff4741c2c96e8cae008048cc576daa5d76dc33cbd63dea;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128494 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x9a53e2626e90094027acc7ecc75633d1abe736d5340deb0645f3ea14822d4cf2;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128493 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xd7e03f2b5b0feb9dbe71659a71df2cabfeffe3f65eafec8c632b2c17d123a565;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128492 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xd67c2d0cc8c0f1e1f5be8fda146b0d167397f18d139f38eb9da1b3eaf3414dea;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128491 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x93f0b0b8c2ccabddc1c07cfaa996433d81223d91730d88fdad54804e305db8f9;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128490 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x2335ea8e9d4f0485ff8be5691160b03a5addbdfb8e02a3f7f080c3dcc19c9944;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128488 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xa6189e72789f643eec450a3e02b87d6931c7ed4bae9ac8181c79dc9352570274;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128487 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x5f08e0b445ec32b8bc3024359757af602777a7f1f79d3e2ec2838d5c2e13d704;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128486 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xf03bc20cf469641ef46dfcd8c0749e81d2dfa678781b0b59308ff1c29fb329d4;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128485 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xb508657ce12647ef390fa5c91834ab66e531fdb8dce356e36bbf717d3d94b696;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128484 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x3873ec57227b252e1257b289828722dcffa8245d5944102981e2870b5c7c00f8;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128482 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x672bebee9db3cad834b1534e6788e3a2d1fd239531caed5ea8a3ed1a6a1ab45a;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128481 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0xc9b13eea0113427a72a055767f015187ef3af07a18a84c2eacae887756f9219a;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128480 /* [1.284e5] */,
        //         sides: sides
        //     });
        // }

        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x92c801c7e325122d296d07d27c254ad37858a3358423d0401f38077f5a3aae4f;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128540 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // {
        //     bytes32[] memory sides = new bytes32[](1);
        //     sides[0] = 0x4fb886c527b4ab9848965f039693acd91b9c0b3bcbeab58989bb1df2be75da95;
        //     dependencyRootsReordered[i++] = InteropRoot({
        //         chainId: 123,
        //         blockOrBatchNumber: 128593 /* [1.285e5] */,
        //         sides: sides
        //     });
        // }
        // bytes32 dependencyRootsRollingHash2;

        // for (uint256 i = 0; i < dependencyRootsReordered.length; i++) {
        //     InteropRoot memory interopRoot = dependencyRootsReordered[i];

        //     dependencyRootsRollingHash2 = keccak256(
        //         // solhint-disable-next-line func-named-parameters
        //         abi.encodePacked(
        //             dependencyRootsRollingHash2,
        //             interopRoot.chainId,
        //             interopRoot.blockOrBatchNumber,
        //             interopRoot.sides
        //         )
        //     );
        // }
    }

    function decode(
        bytes calldata data,
        uint256 from
    ) public view returns (IExecutor.StoredBatchInfo[] memory, PriorityOpsBatchInfo[] memory, InteropRoot[][] memory) {
        (
            IExecutor.StoredBatchInfo[] memory storedBatchInfos,
            PriorityOpsBatchInfo[] memory priorityOpsBatchInfos,
            InteropRoot[][] memory dependencyRoots,
            ,
            ,

        ) = BatchDecoder.decodeAndCheckExecuteData(data, from, from);
        return (storedBatchInfos, priorityOpsBatchInfos, dependencyRoots);
    }
}
