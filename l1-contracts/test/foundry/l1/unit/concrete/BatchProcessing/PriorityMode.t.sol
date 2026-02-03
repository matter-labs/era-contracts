// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {IExecutor, SystemLogKey, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {InvalidTxCountInPriorityMode, OnlyNormalMode, PriorityModeActivationTooEarly, PriorityModeIsNotAllowed, PriorityOpsRequestTimestampMissing, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {PACKED_NUMBER_OF_L2_TRANSACTIONS_LOG_SPLIT_BITS, PRIORITY_EXPIRATION, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";

contract PriorityModeExecutorTest is ExecutorTest {
    function test_revertWhen_activatePriorityMode_notAllowed() public {
        vm.expectRevert(PriorityModeIsNotAllowed.selector);
        admin.activatePriorityMode();
    }

    function test_revertWhen_activatePriorityMode_missingTimestamp() public {
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();

        vm.expectRevert(abi.encodeWithSelector(PriorityOpsRequestTimestampMissing.selector, 0));
        admin.activatePriorityMode();
    }

    function test_revertWhen_activatePriorityMode_tooEarly() public {
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();

        vm.warp(100);
        uint256 requestTimestamp = _requestPriorityOp();
        uint256 earliest = requestTimestamp + PRIORITY_EXPIRATION;

        vm.warp(earliest - 1);
        vm.expectRevert(abi.encodeWithSelector(PriorityModeActivationTooEarly.selector, earliest, earliest - 1));
        admin.activatePriorityMode();
    }

    function test_revertWhen_validatorCommitsInPriorityMode() public {
        _activatePriorityMode();

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        committer.commitBatchesSharedBridge(address(0), 0, 0, "");
    }

    function test_revertWhen_precommitInPriorityMode() public {
        _activatePriorityMode();

        vm.prank(validator);
        vm.expectRevert(OnlyNormalMode.selector);
        committer.precommitSharedBridge(address(0), 1, "");
    }

    function test_revertWhen_priorityModeBatchHasL2Txs() public {
        _activatePriorityMode();

        CommitBatchInfo memory commitInfo = newCommitBatchInfo;

        (bytes32 l2DAValidatorOutputHash, bytes memory operatorDAInput) = _mockDAForCommit(commitInfo.batchNumber);
        bytes[] memory logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        uint256 l2TxCount = 1;
        uint256 packedTxCounts = l2TxCount << PACKED_NUMBER_OF_L2_TRANSACTIONS_LOG_SPLIT_BITS;
        logs[uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(packedTxCounts)
        );

        commitInfo.systemLogs = Utils.encodePacked(logs);
        commitInfo.operatorDAInput = operatorDAInput;
        commitInfo.timestamp = uint64(currentTimestamp);

        CommitBatchInfo[] memory commitInfos = new CommitBatchInfo[](1);
        commitInfos[0] = commitInfo;

        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            commitInfos
        );

        vm.prank(address(permissionlessValidator));
        vm.expectRevert(abi.encodeWithSelector(InvalidTxCountInPriorityMode.selector, l2TxCount, 0));
        committer.commitBatchesSharedBridge(address(0), commitFrom, commitTo, commitData);
    }

    function test_revertWhen_priorityModeBatchHasNoL1Txs() public {
        _activatePriorityMode();

        CommitBatchInfo memory commitInfo = newCommitBatchInfo;

        (bytes32 l2DAValidatorOutputHash, bytes memory operatorDAInput) = _mockDAForCommit(commitInfo.batchNumber);
        bytes[] memory logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        uint256 l1TxCount = 0;
        uint256 l2TxCount = 0;
        uint256 packedTxCounts = l1TxCount | (l2TxCount << PACKED_NUMBER_OF_L2_TRANSACTIONS_LOG_SPLIT_BITS);
        logs[uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(packedTxCounts)
        );

        commitInfo.numberOfLayer1Txs = l1TxCount;
        commitInfo.systemLogs = Utils.encodePacked(logs);
        commitInfo.operatorDAInput = operatorDAInput;
        commitInfo.timestamp = uint64(currentTimestamp);

        CommitBatchInfo[] memory commitInfos = new CommitBatchInfo[](1);
        commitInfos[0] = commitInfo;

        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            commitInfos
        );

        vm.prank(address(permissionlessValidator));
        vm.expectRevert(abi.encodeWithSelector(InvalidTxCountInPriorityMode.selector, l2TxCount, l1TxCount));
        committer.commitBatchesSharedBridge(address(0), commitFrom, commitTo, commitData);
    }

    function _activatePriorityMode() internal {
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();
        _requestPriorityOp();
        vm.warp(block.timestamp + PRIORITY_EXPIRATION + 1);
        admin.activatePriorityMode();
    }

    function _requestPriorityOp() internal returns (uint256 requestTimestamp) {
        address prioritySender = makeAddr("prioritySender");
        uint256 l2GasLimit = 1_000_000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(10_000_000, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        vm.deal(prioritySender, baseCost);
        requestTimestamp = block.timestamp;
        vm.prank(prioritySender);
        mailbox.requestL2Transaction{value: baseCost}({
            _contractL2: makeAddr("l2Contract"),
            _l2Value: 0,
            _calldata: "",
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: new bytes[](0),
            _refundRecipient: prioritySender
        });
    }

    function _mockDAForCommit(
        uint256 batchNumber
    ) internal returns (bytes32 l2DAValidatorOutputHash, bytes memory operatorDAInput) {
        l2DAValidatorOutputHash = bytes32(0);
        operatorDAInput = "";

        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        L1DAValidatorOutput memory daOutput = L1DAValidatorOutput({
            stateDiffHash: bytes32(0),
            blobsLinearHashes: blobHashes,
            blobsOpeningCommitments: blobCommitments
        });
        vm.mockCall(
            rollupL1DAValidator,
            abi.encodeWithSelector(
                IL1DAValidator.checkDA.selector,
                l2ChainId,
                batchNumber,
                l2DAValidatorOutputHash,
                operatorDAInput,
                TOTAL_BLOBS_IN_COMMITMENT
            ),
            abi.encode(daOutput)
        );
    }
}
