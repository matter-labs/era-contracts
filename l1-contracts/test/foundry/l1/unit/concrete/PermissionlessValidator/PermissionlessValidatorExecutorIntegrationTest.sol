// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExecutorTest} from "../BatchProcessing/_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {PRIORITY_EXPIRATION, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract PermissionlessValidatorExecutorIntegrationTest is ExecutorTest {
    function setUp() public {
        _activatePriorityMode();
    }

    function _activatePriorityMode() internal override {
        vm.prank(owner);
        admin.makePermanentRollup();
        address prioritySender = makeAddr("prioritySender");
        uint256 l2GasLimit = 1_000_000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(10_000_000, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        vm.deal(prioritySender, baseCost);
        vm.prank(prioritySender);
        dummyBridgehub.requestL2TransactionDirect{value: baseCost}(
            L2TransactionRequestDirect({
                chainId: l2ChainId,
                mintValue: baseCost,
                l2Contract: makeAddr("l2Contract"),
                l2Value: 0,
                l2Calldata: "",
                l2GasLimit: l2GasLimit,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                refundRecipient: prioritySender
            })
        );
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();
        vm.warp(block.timestamp + PRIORITY_EXPIRATION + 1);
        admin.activatePriorityMode();
    }

    function test_settleBatchesSharedBridge_withExecutor() public {
        PriorityOpsBatchInfo[] memory priorityOps = Utils.generatePriorityOps(1, 1);
        CommitBatchInfoZKsyncOS memory commitInfo = _prepareCommitInfo(priorityOps);
        _mockDAValidator(commitInfo.batchNumber);

        (
            uint256 txFrom,
            uint256 txTo,
            bytes memory commitData,
            bytes memory proveData,
            bytes memory executeData
        ) = _encodeSettleData(commitInfo, priorityOps);

        permissionlessValidator.settleBatchesSharedBridge({
            _chainAddress: address(executor),
            _processBatchFrom: txFrom,
            _processBatchTo: txTo,
            _commitData: commitData,
            _proveData: proveData,
            _executeData: executeData
        });

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 1);
        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(getters.l2LogsRootHash(1), commitInfo.l2LogsTreeRoot);
    }

    function _prepareCommitInfo(
        PriorityOpsBatchInfo[] memory priorityOps
    ) internal returns (CommitBatchInfoZKsyncOS memory commitInfo) {
        bytes32 rollingHash = _rollingHash(priorityOps[0].itemHashes);
        bytes32[] memory merkleItemHashes = new bytes32[](priorityOps[0].itemHashes.length);
        for (uint256 i = 0; i < priorityOps[0].itemHashes.length; ++i) {
            merkleItemHashes[i] = priorityOps[0].itemHashes[i];
        }
        bytes32 expectedRoot = Merkle.calculateRootPaths(
            priorityOps[0].leftPath,
            priorityOps[0].rightPath,
            0,
            merkleItemHashes
        );
        executor.setPriorityTreeHistoricalRoot(expectedRoot);
        commitInfo = _buildCommitInfoZKsyncOS(rollingHash, priorityOps[0].itemHashes.length);
    }

    function _mockDAValidator(uint256 batchNumber) internal {
        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        vm.mockCall(
            rollupL1DAValidator,
            abi.encodeWithSelector(IL1DAValidator.checkDA.selector, l2ChainId, batchNumber),
            abi.encode(
                L1DAValidatorOutput({
                    stateDiffHash: bytes32(0),
                    blobsLinearHashes: blobHashes,
                    blobsOpeningCommitments: blobCommitments
                })
            )
        );
    }

    function _encodeSettleData(
        CommitBatchInfoZKsyncOS memory commitInfo,
        PriorityOpsBatchInfo[] memory priorityOps
    )
        internal
        view
        returns (
            uint256 txFrom,
            uint256 txTo,
            bytes memory commitData,
            bytes memory proveData,
            bytes memory executeData
        )
    {
        CommitBatchInfoZKsyncOS[] memory commitInfos = new CommitBatchInfoZKsyncOS[](1);
        commitInfos[0] = commitInfo;
        (txFrom, txTo, commitData) = Utils.encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, commitInfos);

        IExecutor.StoredBatchInfo[] memory storedArray = new IExecutor.StoredBatchInfo[](1);
        storedArray[0] = _buildStoredBatchInfoZKsyncOS(genesisStoredBatchInfo, commitInfo);

        (, , proveData) = Utils.encodeProveBatchesData(genesisStoredBatchInfo, storedArray, proofInput);
        (, , executeData) = Utils.encodeExecuteBatchesData(storedArray, priorityOps);
    }

    /// @dev Builds a ZKsync OS commit batch info for a priority-mode batch (no L2 txs).
    function _buildCommitInfoZKsyncOS(
        bytes32 priorityOpsHash,
        uint256 numberOfLayer1Txs
    ) internal view returns (CommitBatchInfoZKsyncOS memory info) {
        info = newCommitBatchInfoZKsyncOS;
        info.numberOfLayer1Txs = numberOfLayer1Txs;
        info.numberOfLayer2Txs = 0;
        info.priorityOperationsHash = priorityOpsHash;
        // No interop roots are submitted during execution so the accumulated value is bytes32(0)
        info.dependencyRootsRollingHash = bytes32(0);
    }

    /// @notice Constructs the expected stored batch from its authenticated predecessor and commit data.
    function _buildStoredBatchInfoZKsyncOS(
        IExecutor.StoredBatchInfo memory _previousBatch,
        CommitBatchInfoZKsyncOS memory _commitInfo
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        return
            IExecutor.StoredBatchInfo({
                batchNumber: _commitInfo.batchNumber,
                batchHash: _commitInfo.newStateCommitment,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: _commitInfo.numberOfLayer1Txs,
                priorityOperationsHash: _commitInfo.priorityOperationsHash,
                l2LogsTreeRoot: _commitInfo.l2LogsTreeRoot,
                dependencyRootsRollingHash: _commitInfo.dependencyRootsRollingHash,
                timestamp: 0,
                commitment: keccak256(
                    abi.encodePacked(
                        _previousBatch.batchHash,
                        _commitInfo.newStateCommitment,
                        _commitInfo.chainConfigHash,
                        _batchOutputHash(_commitInfo, bytes32(0))
                    )
                )
            });
    }

    function _rollingHash(bytes32[] memory hashes) internal pure returns (bytes32) {
        bytes32 rollingHash = keccak256("");
        for (uint256 i = 0; i < hashes.length; ++i) {
            rollingHash = keccak256(bytes.concat(rollingHash, hashes[i]));
        }
        return rollingHash;
    }
}
