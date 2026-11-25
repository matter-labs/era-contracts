// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    GOLDEN_CHAIN_ID,
    BATCH_OUTPUT_HASH_GOLDEN,
    PUBLIC_INPUT_HASH_GOLDEN,
    PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY,
    PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY,
    PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS
} from "foundry-test/TestConstants.sol";

import {ZKsyncOSBatchCommitment} from "contracts/state-transition/libraries/ZKsyncOSBatchCommitment.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    L2DACommitmentScheme,
    PubdataContent,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
    ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED
} from "contracts/common/Config.sol";

/// @notice The commitment code exactly as `CommitterFacet` and `ZKChainBase` had it before it moved to
/// `ZKsyncOSBatchCommitment`, frozen here as the reference of the differential tests below.
library FrozenCommitterCommitment {
    /// @dev `ZKChainBase._getZKsyncOSChainConfigHash`, with the storage reads turned into parameters.
    function getZKsyncOSChainConfigHash(
        uint256 _chainId,
        uint64 _maxTxGasLimit,
        PubdataContent _pubdataContent,
        bool _l1TxFilteringEnabled,
        bool _largeContractsEnabled
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _chainId,
                    ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED,
                    uint256(_maxTxGasLimit),
                    uint256(_pubdataContent),
                    uint256(_l1TxFilteringEnabled ? 1 : 0),
                    uint256(_largeContractsEnabled ? 1 : 0)
                )
            );
    }

    /// @dev `CommitterFacet._getBatchOutputHash`.
    function getBatchOutputHash(
        CommitBatchInfoZKsyncOS memory _batch,
        bytes32 _upgradeTxHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
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
                    _batch.slChainId,
                    _batch.interopFeeUnits
                )
            );
    }

    /// @dev `CommitterFacet._getBatchCommitment`.
    function getBatchCommitment(
        bytes32 _previousState,
        bytes32 _newState,
        bytes32 _chainConfigHash,
        bytes32 _batchOutputHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_previousState, _newState, _chainConfigHash, _batchOutputHash));
    }

    /// @dev The `StoredBatchInfo` built in `CommitterFacet._commitOneBatch`.
    function storedBatchInfo(
        IExecutor.StoredBatchInfo memory _previousBatch,
        CommitBatchInfoZKsyncOS memory _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        bytes32 batchOutputHash = getBatchOutputHash(_newBatch, _expectedSystemContractUpgradeTxHash);
        return
            IExecutor.StoredBatchInfo({
                batchNumber: _newBatch.batchNumber,
                batchHash: _newBatch.newStateCommitment,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: _newBatch.numberOfLayer1Txs,
                priorityOperationsHash: _newBatch.priorityOperationsHash,
                l2LogsTreeRoot: _newBatch.l2LogsTreeRoot,
                dependencyRootsRollingHash: _newBatch.dependencyRootsRollingHash,
                timestamp: 0,
                commitment: getBatchCommitment(
                    _previousBatch.batchHash,
                    _newBatch.newStateCommitment,
                    _newBatch.chainConfigHash,
                    batchOutputHash
                )
            });
    }
}

/// @notice `CommitBatchInfoZKsyncOS` with the DA commitment scheme as a plain integer, so the fuzzer never produces
/// an out-of-range enum, which would revert while decoding the test's arguments.
struct FuzzedCommitBatchInfo {
    uint64 batchNumber;
    bytes32 newStateCommitment;
    uint256 numberOfLayer1Txs;
    uint256 numberOfLayer2Txs;
    bytes32 priorityOperationsHash;
    bytes32 dependencyRootsRollingHash;
    bytes32 l2LogsTreeRoot;
    uint8 daCommitmentScheme;
    bytes32 daCommitment;
    uint64 firstBlockTimestamp;
    uint64 firstBlockNumber;
    uint64 lastBlockTimestamp;
    uint64 lastBlockNumber;
    uint256 chainId;
    bytes operatorDAInput;
    uint256 slChainId;
    bytes32 chainConfigHash;
    uint256 interopFeeUnits;
}

/// @notice Differential tests of `ZKsyncOSBatchCommitment` against the frozen committer code, plus the
/// ZKsync OS golden vectors. That the facets use the library is covered by the batch-processing suites.
contract ZKsyncOSBatchCommitmentTest is Test {
    function testFuzz_chainConfigHash_matchesFrozenCommitter(
        uint256 _chainId,
        uint64 _maxTxGasLimit,
        bool _logsOnly,
        bool _l1TxFilteringEnabled,
        bool _largeContractsEnabled
    ) public pure {
        PubdataContent pubdataContent = _logsOnly ? PubdataContent.LOGS_ONLY : PubdataContent.FULL_PUBDATA;
        assertEq(
            ZKsyncOSBatchCommitment.chainConfigHash(
                _chainId,
                _maxTxGasLimit,
                pubdataContent,
                _l1TxFilteringEnabled,
                _largeContractsEnabled
            ),
            FrozenCommitterCommitment.getZKsyncOSChainConfigHash(
                _chainId,
                _maxTxGasLimit,
                pubdataContent,
                _l1TxFilteringEnabled,
                _largeContractsEnabled
            )
        );
    }

    function testFuzz_batchOutputHash_matchesFrozenCommitter(
        FuzzedCommitBatchInfo memory _fuzzed,
        bytes32 _upgradeTxHash
    ) public pure {
        CommitBatchInfoZKsyncOS memory _batch = _toCommitBatchInfo(_fuzzed);
        assertEq(
            ZKsyncOSBatchCommitment.batchOutputHash(_batch, _upgradeTxHash),
            FrozenCommitterCommitment.getBatchOutputHash(_batch, _upgradeTxHash)
        );
    }

    function testFuzz_batchCommitment_matchesFrozenCommitter(
        bytes32 _previousState,
        bytes32 _newState,
        bytes32 _chainConfigHash,
        bytes32 _batchOutputHash
    ) public pure {
        assertEq(
            ZKsyncOSBatchCommitment.batchCommitment(_previousState, _newState, _chainConfigHash, _batchOutputHash),
            FrozenCommitterCommitment.getBatchCommitment(_previousState, _newState, _chainConfigHash, _batchOutputHash)
        );
    }

    function testFuzz_storedBatchInfo_matchesFrozenCommitter(
        IExecutor.StoredBatchInfo memory _previousBatch,
        FuzzedCommitBatchInfo memory _fuzzed,
        bytes32 _upgradeTxHash
    ) public pure {
        CommitBatchInfoZKsyncOS memory _batch = _toCommitBatchInfo(_fuzzed);
        IExecutor.StoredBatchInfo memory actual = ZKsyncOSBatchCommitment.storedBatchInfo(
            _previousBatch.batchHash,
            _batch,
            _upgradeTxHash
        );
        IExecutor.StoredBatchInfo memory expected = FrozenCommitterCommitment.storedBatchInfo(
            _previousBatch,
            _batch,
            _upgradeTxHash
        );
        assertEq(abi.encode(actual), abi.encode(expected));
    }

    /// @notice Every field the batch output hashes changes it, and the upgrade transaction hash does too.
    function test_batchOutputHash_commitsToEveryOutput() public pure {
        CommitBatchInfoZKsyncOS memory batch = _goldenBatch();
        bytes32 base = ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0));

        assertNotEq(ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(uint256(1))), base);
        batch.l2LogsTreeRoot = keccak256("forged");
        assertNotEq(ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0)), base);
        batch = _goldenBatch();
        batch.slChainId += 1;
        assertNotEq(ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0)), base);
        batch = _goldenBatch();
        batch.interopFeeUnits += 1;
        assertNotEq(ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0)), base);
    }

    /// @notice The fields a settlement layer reads from storage rather than from the batch output do
    /// not enter the batch output hash; the commitment binds them through the state commitments and
    /// the chain config hash instead.
    function test_batchOutputHash_ignoresFieldsOutsideTheOutput() public pure {
        CommitBatchInfoZKsyncOS memory batch = _goldenBatch();
        bytes32 base = ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0));

        batch.batchNumber = 77;
        batch.newStateCommitment = keccak256("state");
        batch.firstBlockNumber = 5;
        batch.lastBlockNumber = 6;
        batch.chainId = 1234;
        batch.operatorDAInput = hex"01";
        batch.chainConfigHash = keccak256("config");
        assertEq(ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0)), base);
    }

    /// @notice The ZKsync OS golden vectors pinned by `ZKsyncOSPublicInputTest`, through the library.
    function test_matchesZKsyncOSGoldenVectors() public pure {
        assertEq(_goldenPublicInput(false, false), PUBLIC_INPUT_HASH_GOLDEN);
        assertEq(_goldenPublicInput(true, false), PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY);
        assertEq(_goldenPublicInput(false, true), PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY);
        assertEq(_goldenPublicInput(true, true), PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS);
    }

    function test_storedBatchInfo_isCanonical() public pure {
        CommitBatchInfoZKsyncOS memory batch = _goldenBatch();
        batch.batchNumber = 9;
        batch.newStateCommitment = keccak256("new state");
        batch.chainConfigHash = keccak256("config");
        IExecutor.StoredBatchInfo memory stored = ZKsyncOSBatchCommitment.storedBatchInfo(
            keccak256("previous state"),
            batch,
            bytes32(0)
        );

        assertEq(stored.batchNumber, 9);
        assertEq(stored.batchHash, batch.newStateCommitment);
        assertEq(stored.indexRepeatedStorageChanges, 0);
        assertEq(stored.timestamp, 0);
        assertEq(stored.l2LogsTreeRoot, batch.l2LogsTreeRoot);
        assertEq(
            stored.commitment,
            ZKsyncOSBatchCommitment.batchCommitment(
                keccak256("previous state"),
                batch.newStateCommitment,
                batch.chainConfigHash,
                ZKsyncOSBatchCommitment.batchOutputHash(batch, bytes32(0))
            )
        );
    }

    function _goldenPublicInput(
        bool _l1TxFilteringEnabled,
        bool _largeContractsEnabled
    ) internal pure returns (bytes32) {
        return
            ZKsyncOSBatchCommitment.batchCommitment(
                bytes32(0),
                bytes32(0),
                ZKsyncOSBatchCommitment.chainConfigHash(
                    GOLDEN_CHAIN_ID,
                    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
                    PubdataContent.FULL_PUBDATA,
                    _l1TxFilteringEnabled,
                    _largeContractsEnabled
                ),
                BATCH_OUTPUT_HASH_GOLDEN
            );
    }

    function _toCommitBatchInfo(
        FuzzedCommitBatchInfo memory _fuzzed
    ) internal pure returns (CommitBatchInfoZKsyncOS memory batch) {
        batch.batchNumber = _fuzzed.batchNumber;
        batch.newStateCommitment = _fuzzed.newStateCommitment;
        batch.numberOfLayer1Txs = _fuzzed.numberOfLayer1Txs;
        batch.numberOfLayer2Txs = _fuzzed.numberOfLayer2Txs;
        batch.priorityOperationsHash = _fuzzed.priorityOperationsHash;
        batch.dependencyRootsRollingHash = _fuzzed.dependencyRootsRollingHash;
        batch.l2LogsTreeRoot = _fuzzed.l2LogsTreeRoot;
        batch.daCommitmentScheme = L2DACommitmentScheme(
            _fuzzed.daCommitmentScheme % (uint8(type(L2DACommitmentScheme).max) + 1)
        );
        batch.daCommitment = _fuzzed.daCommitment;
        batch.firstBlockTimestamp = _fuzzed.firstBlockTimestamp;
        batch.firstBlockNumber = _fuzzed.firstBlockNumber;
        batch.lastBlockTimestamp = _fuzzed.lastBlockTimestamp;
        batch.lastBlockNumber = _fuzzed.lastBlockNumber;
        batch.chainId = _fuzzed.chainId;
        batch.operatorDAInput = _fuzzed.operatorDAInput;
        batch.slChainId = _fuzzed.slChainId;
        batch.chainConfigHash = _fuzzed.chainConfigHash;
        batch.interopFeeUnits = _fuzzed.interopFeeUnits;
    }

    function _goldenBatch() internal pure returns (CommitBatchInfoZKsyncOS memory batch) {
        batch.firstBlockTimestamp = 1;
        batch.lastBlockTimestamp = 2;
        batch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        batch.daCommitment = keccak256("da");
        batch.numberOfLayer1Txs = 3;
        batch.numberOfLayer2Txs = 4;
        batch.priorityOperationsHash = keccak256("priority");
        batch.l2LogsTreeRoot = keccak256("logs");
        batch.dependencyRootsRollingHash = keccak256("dependencies");
        batch.slChainId = 31337;
        batch.interopFeeUnits = 7;
    }
}
