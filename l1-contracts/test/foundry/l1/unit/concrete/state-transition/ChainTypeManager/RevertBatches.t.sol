// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_DA_COMMITMENT_SCHEME, Utils} from "../../Utils/Utils.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {UtilsFacet} from "../../Utils/UtilsFacet.sol";

import {
    DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    PUBLIC_INPUT_SHIFT,
    TESTNET_COMMIT_TIMESTAMP_NOT_OLDER,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
    ZKSYNC_OS_MOCK_PROOF_MAGIC,
    ZKSYNC_OS_MOCK_VERIFICATION_TYPE
} from "contracts/common/Config.sol";
import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract RevertBatchesTest is ChainTypeManagerTest {
    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    address internal newChainAddress;

    AdminFacet internal adminFacet;
    ExecutorFacet internal executorFacet;
    CommitterFacet internal committerFacet;
    GettersFacet internal gettersFacet;

    function setUp() public {
        deploy();

        genesisStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: bytes32(uint256(1)),
            indexRepeatedStorageChanges: 1,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: 0,
            commitment: bytes32(uint256(1))
        });

        mockDiamondInitInteropCenterCallsWithAddress(address(bridgehub), sharedBridge, baseTokenAssetId);
        newChainAddress = createNewChain(getDiamondCutData(diamondInit));
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(newChainAddress)
        );

        executorFacet = ExecutorFacet(newChainAddress);
        committerFacet = CommitterFacet(newChainAddress);
        gettersFacet = GettersFacet(newChainAddress);
        adminFacet = AdminFacet(newChainAddress);

        vm.prank(newChainAdmin);
        adminFacet.setDAValidatorPair(address(rollupL1DAValidator), L2_DA_COMMITMENT_SCHEME);

        bytes32[] memory zeroBlobValues = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        vm.mockCall(
            address(rollupL1DAValidator),
            abi.encodeWithSelector(IL1DAValidator.checkDA.selector, chainId, uint256(1)),
            abi.encode(
                L1DAValidatorOutput({
                    stateDiffHash: bytes32(0),
                    blobsLinearHashes: zeroBlobValues,
                    blobsOpeningCommitments: zeroBlobValues
                })
            )
        );
    }

    function test_SuccessfulBatchReverting() public {
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 2);

        CommitBatchInfoZKsyncOS memory newBatch = CommitBatchInfoZKsyncOS({
            batchNumber: 1,
            newStateCommitment: Utils.randomBytes32("newStateCommitment"),
            numberOfLayer1Txs: 0,
            numberOfLayer2Txs: 0,
            priorityOperationsHash: keccak256(""),
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: Utils.randomBytes32("l2LogsTreeRoot"),
            daCommitmentScheme: L2_DA_COMMITMENT_SCHEME,
            daCommitment: bytes32(0),
            firstBlockTimestamp: uint64(block.timestamp),
            firstBlockNumber: 1,
            lastBlockTimestamp: uint64(block.timestamp),
            lastBlockNumber: 2,
            chainId: chainId,
            operatorDAInput: bytes(""),
            slChainId: block.chainid
        });

        bytes32 upgradeTxHash = gettersFacet.getL2SystemContractsUpgradeTxHash();
        IExecutor.StoredBatchInfo memory storedBatchInfo = _storedBatchInfo(newBatch, upgradeTxHash);

        CommitBatchInfoZKsyncOS[] memory batches = new CommitBatchInfoZKsyncOS[](1);
        batches[0] = newBatch;
        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesDataZKsyncOS(
            genesisStoredBatchInfo,
            batches
        );

        vm.prank(validator);
        committerFacet.commitBatchesSharedBridge(address(0), commitFrom, commitTo, commitData);

        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatchInfo;
        uint256[] memory proof = _mockProof(genesisStoredBatchInfo, storedBatchInfo);
        (uint256 proveFrom, uint256 proveTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatches,
            proof
        );

        vm.prank(validator);
        executorFacet.proveBatchesSharedBridge(address(0), proveFrom, proveTo, proveData);

        assertEq(gettersFacet.getTotalBatchesCommitted(), 1);
        assertEq(gettersFacet.getTotalBatchesVerified(), 1);

        vm.prank(governor);
        chainContractAddress.revertBatches(chainId, 0);

        assertEq(gettersFacet.getTotalBatchesCommitted(), 0);
        assertEq(gettersFacet.getTotalBatchesVerified(), 0);
    }

    function _storedBatchInfo(
        CommitBatchInfoZKsyncOS memory _batch,
        bytes32 _upgradeTxHash
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        bytes32 batchOutputHash = keccak256(
            abi.encodePacked(
                _batch.firstBlockTimestamp,
                _batch.lastBlockTimestamp,
                uint256(_batch.daCommitmentScheme),
                _batch.daCommitment,
                _batch.numberOfLayer1Txs,
                _batch.numberOfLayer2Txs,
                _batch.priorityOperationsHash,
                _batch.l2LogsTreeRoot,
                _upgradeTxHash,
                _batch.dependencyRootsRollingHash,
                _batch.slChainId
            )
        );

        return
            IExecutor.StoredBatchInfo({
                batchNumber: _batch.batchNumber,
                batchHash: _batch.newStateCommitment,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: _batch.numberOfLayer1Txs,
                priorityOperationsHash: _batch.priorityOperationsHash,
                l2LogsTreeRoot: _batch.l2LogsTreeRoot,
                dependencyRootsRollingHash: _batch.dependencyRootsRollingHash,
                timestamp: 0,
                commitment: batchOutputHash
            });
    }

    function _mockProof(
        IExecutor.StoredBatchInfo memory _previousBatch,
        IExecutor.StoredBatchInfo memory _currentBatch
    ) internal view returns (uint256[] memory proof) {
        UtilsFacet utilsFacet = UtilsFacet(newChainAddress);
        uint256 maxTxGasLimit = utilsFacet.util_getZKsyncOSMaxTxGasLimit();
        if (maxTxGasLimit == 0) {
            maxTxGasLimit = ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT;
        }
        bytes32 chainConfigHash = keccak256(
            abi.encodePacked(chainId, uint256(0), maxTxGasLimit, uint256(utilsFacet.util_getPubdataContent()))
        );
        uint256 publicInput = uint256(
            keccak256(
                abi.encodePacked(
                    _previousBatch.batchHash,
                    _currentBatch.batchHash,
                    chainConfigHash,
                    _currentBatch.commitment
                )
            )
        ) >> PUBLIC_INPUT_SHIFT;

        proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_MOCK_VERIFICATION_TYPE;
        proof[1] = 0;
        proof[2] = ZKSYNC_OS_MOCK_PROOF_MAGIC;
        proof[3] = publicInput;
    }
}
