// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {L2_SYSTEM_CONTEXT_ADDRESS, L2_TO_L1_MESSENGER, Utils} from "../l1/unit/concrete/Utils/Utils.sol";

import {
    COMMIT_TIMESTAMP_APPROXIMATION_DELTA,
    EMPTY_STRING_KECCAK,
    ERA_MULTI_PROOF_TYPE,
    L2DACommitmentScheme
} from "contracts/common/Config.sol";
import {
    AirbenderCommitmentRequired,
    BatchHashMismatch,
    CantExecuteUnprovenBatches,
    InvalidProofFormat,
    MissingSystemLogs,
    TxHashMismatch,
    UnsupportedCommitBatchEncoding
} from "contracts/common/L1ContractErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {CommitBatchInfo, ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor, MAX_LOG_KEY, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {PubdataSource} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";

/// @title V34EraStageFirstBatchForkTest
/// @notice A chain's first v34 batches on its L1 state (stage's 499, testnet3's 312): the upgrade batch commits on
/// the last v33 batch, proves and executes, the next batch chains on it, and what an operator could get wrong at the
/// boundary reverts.
/// @dev Runs only from `upgrade-envs/v0.34.0-era/rehearse.sh`, forked from its Anvil fork after the chain's
/// upgrade. The script exports the environment's facts and `V34_PREV_BATCH`, the last v33 batch's stored info
/// decoded from its execute transaction. The batches are synthetic: nothing runs on L2, and the testnet verifier
/// accepts the empty proof, so this does not exercise public inputs or verification keys.
contract V34EraStageFirstBatchForkTest is Test {
    // Synthetic batch contents: L1 only needs them to be non-zero and consistent.
    bytes32 internal constant STATE_DIFF_HASH = keccak256("v34 fork test: state diff hash");
    bytes32 internal constant BLOB_LINEAR_HASH = keccak256("v34 fork test: blob linear hash");
    bytes32 internal constant BLOB_COMMITMENT = keccak256("v34 fork test: blob commitment");
    bytes32 internal constant BOOTLOADER_HEAP_HASH = keccak256("v34 fork test: bootloader heap hash");
    bytes32 internal constant EVENTS_QUEUE_HASH = keccak256("v34 fork test: events queue hash");
    bytes32 internal constant AIRBENDER_HEAP_HASH = keccak256("v34 fork test: Airbender bootloader heap hash");
    /// @dev Calldata DA always declares one blob: its linear hash and commitment, with the pubdata (empty here).
    uint8 internal constant CALLDATA_BLOBS = 1;
    /// @dev The commit encoding v33 operators send.
    uint8 internal constant V33_ENCODING_VERSION = 1;

    IZKChain internal chain;
    ValidatorTimelock internal validatorTimelock;
    IMessageRootBase internal messageRoot;
    uint256 internal chainId;
    /// @dev An EOA holding the chain's committer role.
    address internal committer;
    /// @dev An EOA holding the chain's prover and executor roles. Chain 312's is not its committer.
    address internal prover;
    uint32 internal executionDelay;
    uint256 internal daCommitmentScheme;
    bytes32 internal upgradeTxHash;
    /// @dev The last v33 batch in v34's layout, with no Airbender commitment.
    IExecutor.StoredBatchInfo internal lastV33Batch;
    /// @dev The first v34 batch, which must carry the L2 upgrade transaction.
    uint256 internal upgradeBatchNumber;

    function setUp() public {
        bytes memory prevBatch = vm.envOr("V34_PREV_BATCH", bytes(""));
        if (prevBatch.length == 0) {
            vm.skip(true, "run from rehearse.sh");
        }
        assertEq(block.chainid, vm.envUint("L1_CHAIN_ID"), "not a fork of the environment's L1");

        chain = IZKChain(vm.envAddress("DIAMOND"));
        validatorTimelock = ValidatorTimelock(vm.envAddress("VT"));
        messageRoot = IBridgehubBase(vm.envAddress("BRIDGEHUB")).messageRoot();
        chainId = vm.envUint("CHAIN_ID");
        uint256 newProtocolVersion = vm.envUint("NEW");

        // V34_PREV_BATCH is the 9-field pre-Airbender encoding; a zero word appended makes it v34's layout
        // with `airbenderCommitment = 0`, the form the chain accepts for its last v33 batch.
        lastV33Batch = abi.decode(bytes.concat(prevBatch, bytes32(0)), (IExecutor.StoredBatchInfo));
        uint256 lastV33BatchNumber = lastV33Batch.batchNumber;
        upgradeBatchNumber = lastV33BatchNumber + 1;

        assertEq(chain.getChainId(), chainId, "chain id");
        assertEq(chain.storedBatchHash(lastV33BatchNumber), keccak256(prevBatch), "V34_PREV_BATCH stored hash");
        assertEq(chain.getTotalBatchesCommitted(), lastV33BatchNumber, "committed batches");
        assertEq(chain.getTotalBatchesVerified(), lastV33BatchNumber, "verified batches");
        assertEq(chain.getTotalBatchesExecuted(), lastV33BatchNumber, "executed batches");
        assertEq(chain.getProtocolVersion(), newProtocolVersion, "chain protocol version");
        assertTrue(
            IChainTypeManager(vm.envAddress("CTM")).protocolVersionIsActive(newProtocolVersion),
            "v0.34.0 active on the CTM"
        );
        upgradeTxHash = chain.getL2SystemContractsUpgradeTxHash();
        assertTrue(upgradeTxHash != bytes32(0), "pending L2 upgrade tx");
        assertEq(chain.getL2SystemContractsUpgradeBatchNumber(), 0, "upgrade batch not committed yet");

        (, L2DACommitmentScheme scheme) = chain.getDAValidatorPair();
        daCommitmentScheme = uint256(scheme);
        committer = _findEoa(validatorTimelock.COMMITTER_ROLE(), bytes32(0));
        prover = _findEoa(validatorTimelock.PROVER_ROLE(), validatorTimelock.EXECUTOR_ROLE());
        executionDelay = validatorTimelock.executionDelay();
    }

    /// @dev The upgrade batch commits, proves and executes, which clears the pending upgrade; the next batch chains
    /// on its v34 stored info, and the MessageRoot keeps in step.
    function test_firstV34BatchesCommitProveExecute() public {
        IExecutor.StoredBatchInfo memory upgradeBatch = _commit(
            lastV33Batch,
            _batch(lastV33Batch, upgradeTxHash, AIRBENDER_HEAP_HASH)
        );
        assertEq(chain.getTotalBatchesCommitted(), upgradeBatchNumber);
        assertEq(chain.getL2SystemContractsUpgradeBatchNumber(), upgradeBatchNumber);
        assertTrue(upgradeBatch.airbenderCommitment != bytes32(0), "Airbender commitment");

        vm.expectEmit(true, true, true, true, address(chain));
        emit IExecutor.BlocksVerification(upgradeBatchNumber - 1, upgradeBatchNumber);
        _prove(lastV33Batch, upgradeBatch, new uint256[](0));
        assertEq(chain.getTotalBatchesVerified(), upgradeBatchNumber);

        vm.expectEmit(true, true, true, true, address(chain));
        emit IExecutor.BlockExecution(upgradeBatchNumber, upgradeBatch.batchHash, upgradeBatch.commitment);
        _execute(upgradeBatch);
        assertEq(chain.getTotalBatchesExecuted(), upgradeBatchNumber);
        assertEq(chain.getL2SystemContractsUpgradeTxHash(), bytes32(0), "upgrade tx hash cleared");
        assertEq(chain.getL2SystemContractsUpgradeBatchNumber(), 0, "upgrade batch number cleared");
        assertEq(chain.l2LogsRootHash(upgradeBatchNumber), upgradeBatch.l2LogsTreeRoot);
        assertEq(messageRoot.currentChainBatchNumber(chainId), upgradeBatchNumber);
        assertEq(messageRoot.chainBatchRoots(chainId, upgradeBatchNumber), upgradeBatch.l2LogsTreeRoot);

        IExecutor.StoredBatchInfo memory nextBatch = _commit(
            upgradeBatch,
            _batch(upgradeBatch, bytes32(0), AIRBENDER_HEAP_HASH)
        );
        vm.expectEmit(true, true, true, true, address(chain));
        emit IExecutor.BlocksVerification(upgradeBatchNumber, upgradeBatchNumber + 1);
        _prove(upgradeBatch, nextBatch, new uint256[](0));
        vm.expectEmit(true, true, true, true, address(chain));
        emit IExecutor.BlockExecution(upgradeBatchNumber + 1, nextBatch.batchHash, nextBatch.commitment);
        _execute(nextBatch);
        assertEq(chain.getTotalBatchesCommitted(), upgradeBatchNumber + 1);
        assertEq(chain.getTotalBatchesVerified(), upgradeBatchNumber + 1);
        assertEq(chain.getTotalBatchesExecuted(), upgradeBatchNumber + 1);
        assertEq(messageRoot.currentChainBatchNumber(chainId), upgradeBatchNumber + 1);
        assertEq(messageRoot.chainBatchRoots(chainId, upgradeBatchNumber + 1), nextBatch.l2LogsTreeRoot);
    }

    /// @dev The first v34 batch must execute the L2 upgrade transaction.
    function test_upgradeBatchWithoutUpgradeLogReverts() public {
        CommitBatchInfo memory info = _batch(lastV33Batch, bytes32(0), AIRBENDER_HEAP_HASH);
        vm.expectRevert(
            abi.encodeWithSelector(MissingSystemLogs.selector, 2 ** (MAX_LOG_KEY + 1) - 1, 2 ** MAX_LOG_KEY - 1)
        );
        _sendCommit(lastV33Batch, info);
    }

    function test_upgradeBatchWithWrongUpgradeHashReverts() public {
        CommitBatchInfo memory info = _batch(lastV33Batch, keccak256("wrong"), AIRBENDER_HEAP_HASH);
        vm.expectRevert(TxHashMismatch.selector);
        _sendCommit(lastV33Batch, info);
    }

    function test_batchWithoutAirbenderHeapHashReverts() public {
        CommitBatchInfo memory info = _batch(lastV33Batch, upgradeTxHash, bytes32(0));
        vm.expectRevert(AirbenderCommitmentRequired.selector);
        _sendCommit(lastV33Batch, info);
    }

    function test_executeBeforeProveReverts() public {
        IExecutor.StoredBatchInfo memory upgradeBatch = _commit(
            lastV33Batch,
            _batch(lastV33Batch, upgradeTxHash, AIRBENDER_HEAP_HASH)
        );
        vm.expectRevert(CantExecuteUnprovenBatches.selector);
        _execute(upgradeBatch);
    }

    /// @dev A non-empty proof reaches the multi-proof verifier: a real proof is checked, not waved through.
    function test_nonEmptyProofReachesTheVerifiers() public {
        IExecutor.StoredBatchInfo memory upgradeBatch = _commit(
            lastV33Batch,
            _batch(lastV33Batch, upgradeTxHash, AIRBENDER_HEAP_HASH)
        );
        uint256[] memory proof = new uint256[](1);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        vm.expectRevert(InvalidProofFormat.selector);
        _prove(lastV33Batch, upgradeBatch, proof);
    }

    /// @dev The operator must switch to the v34 encoding; the version byte alone decides.
    function test_v33EncodingIsRejected() public {
        CommitBatchInfo[] memory batches = new CommitBatchInfo[](1);
        batches[0] = _batch(lastV33Batch, upgradeTxHash, AIRBENDER_HEAP_HASH);
        IExecutor.StoredBatchInfo memory prev = lastV33Batch;
        bytes memory data = bytes.concat(bytes1(V33_ENCODING_VERSION), abi.encode(prev, batches));
        vm.expectRevert(abi.encodeWithSelector(UnsupportedCommitBatchEncoding.selector, V33_ENCODING_VERSION));
        vm.prank(committer);
        validatorTimelock.commitBatchesSharedBridge(address(chain), upgradeBatchNumber, upgradeBatchNumber, data);
    }

    /// @dev Only the last v33 batch may be passed without an Airbender commitment, not a v34 one.
    function test_v34PredecessorWithoutAirbenderCommitmentReverts() public {
        IExecutor.StoredBatchInfo memory upgradeBatch = _commit(
            lastV33Batch,
            _batch(lastV33Batch, upgradeTxHash, AIRBENDER_HEAP_HASH)
        );
        CommitBatchInfo memory nextBatch = _batch(upgradeBatch, bytes32(0), AIRBENDER_HEAP_HASH);
        bytes32 storedHash = chain.storedBatchHash(upgradeBatchNumber);
        upgradeBatch.airbenderCommitment = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(BatchHashMismatch.selector, storedHash, keccak256(abi.encode(upgradeBatch)))
        );
        _sendCommit(upgradeBatch, nextBatch);
    }

    /// @dev A synthetic batch on top of `_prev`: no transactions, calldata DA with empty pubdata.
    /// @param _upgradeLog The value of the upgrade tx hash log (key 10), or zero to leave the log out.
    function _batch(
        IExecutor.StoredBatchInfo memory _prev,
        bytes32 _upgradeLog,
        bytes32 _airbenderHeapHash
    ) internal returns (CommitBatchInfo memory info) {
        uint256 batchNumber = _prev.batchNumber + 1;
        // L1 requires prev timestamp < batch timestamp <= last L2 block timestamp <= now + 1 hour.
        uint256 timestamp = block.timestamp > _prev.timestamp ? block.timestamp : _prev.timestamp + 1;
        if (timestamp > block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA) {
            vm.warp(timestamp);
        }

        bytes[] memory logs = _upgradeLog == bytes32(0)
            ? Utils.createSystemLogs(bytes32(0))
            : Utils.createSystemLogsWithUpgradeTransaction(_upgradeLog);
        // The MessageRoot rejects a zero logs root.
        _setLog(logs, L2_TO_L1_MESSENGER, SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY, _l2LogsRoot(batchNumber));
        _setLog(
            logs,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
            Utils.packBatchTimestampAndBlockTimestamp(timestamp, timestamp)
        );
        _setLog(logs, L2_SYSTEM_CONTEXT_ADDRESS, SystemLogKey.PREV_BATCH_HASH_KEY, _prev.batchHash);
        _setLog(logs, L2_TO_L1_MESSENGER, SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY, _daOutputHash());
        _setLog(
            logs,
            L2_TO_L1_MESSENGER,
            SystemLogKey.USED_L2_DA_VALIDATION_COMMITMENT_SCHEME_KEY,
            bytes32(daCommitmentScheme)
        );

        info.batchNumber = uint64(batchNumber);
        info.timestamp = uint64(timestamp);
        info.indexRepeatedStorageChanges = _prev.indexRepeatedStorageChanges;
        info.newStateRoot = _stateRoot(batchNumber);
        info.priorityOperationsHash = EMPTY_STRING_KECCAK;
        info.bootloaderHeapInitialContentsHash = BOOTLOADER_HEAP_HASH;
        info.eventsQueueStateHash = EVENTS_QUEUE_HASH;
        info.airbenderBootloaderHeapHash = _airbenderHeapHash;
        info.systemLogs = Utils.encodePacked(logs);
        // Calldata DA: the L2 validator's output (hashed into log 5), then the source and the blob commitment.
        info.operatorDAInput = abi.encodePacked(
            STATE_DIFF_HASH,
            EMPTY_STRING_KECCAK,
            CALLDATA_BLOBS,
            BLOB_LINEAR_HASH,
            uint8(PubdataSource.Calldata),
            BLOB_COMMITMENT
        );
    }

    /// @dev Commits as the committer and returns the batch as the chain stored it; the commitments come from the
    /// commit's events.
    function _commit(
        IExecutor.StoredBatchInfo memory _prev,
        CommitBatchInfo memory _info
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        vm.recordLogs();
        _sendCommit(_prev, _info);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        stored.batchNumber = _info.batchNumber;
        stored.batchHash = _info.newStateRoot;
        stored.indexRepeatedStorageChanges = _info.indexRepeatedStorageChanges;
        stored.priorityOperationsHash = _info.priorityOperationsHash;
        stored.l2LogsTreeRoot = _l2LogsRoot(_info.batchNumber);
        stored.timestamp = _info.timestamp;
        uint256 events = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(chain)) {
                continue;
            }
            if (logs[i].topics[0] == ICommitter.BlockCommit.selector) {
                assertEq(uint256(logs[i].topics[1]), _info.batchNumber, "BlockCommit batch number");
                stored.commitment = logs[i].topics[3];
                ++events;
            } else if (logs[i].topics[0] == ICommitter.BatchAirbenderCommitment.selector) {
                assertEq(uint256(logs[i].topics[1]), _info.batchNumber, "BatchAirbenderCommitment batch number");
                stored.airbenderCommitment = abi.decode(logs[i].data, (bytes32));
                ++events;
            }
        }
        assertEq(events, 2, "one BlockCommit and one BatchAirbenderCommitment");
        assertEq(keccak256(abi.encode(stored)), chain.storedBatchHash(_info.batchNumber), "stored batch hash");
    }

    /// @dev No external call between building the data and the timelock call, so `vm.expectRevert` can precede it.
    function _sendCommit(IExecutor.StoredBatchInfo memory _prev, CommitBatchInfo memory _info) internal {
        CommitBatchInfo[] memory batches = new CommitBatchInfo[](1);
        batches[0] = _info;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeCommitBatchesData(_prev, batches);
        vm.prank(committer);
        validatorTimelock.commitBatchesSharedBridge(address(chain), from, to, data);
    }

    function _prove(
        IExecutor.StoredBatchInfo memory _prev,
        IExecutor.StoredBatchInfo memory _batchInfo,
        uint256[] memory _proof
    ) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _batchInfo;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(_prev, batches, _proof);
        vm.prank(prover);
        validatorTimelock.proveBatchesSharedBridge(address(chain), from, to, data);
    }

    function _execute(IExecutor.StoredBatchInfo memory _batchInfo) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _batchInfo;
        // No priority operations: empty item hashes and paths.
        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](1);
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeExecuteBatchesDataZeroLogs(batches, priorityOps);
        vm.warp(block.timestamp + executionDelay);
        vm.prank(prover);
        validatorTimelock.executeBatchesSharedBridge(address(chain), from, to, data);
    }

    /// @dev The first EOA holding `_role` for the chain, and `_alsoRole` too unless it is zero. The live timelock
    /// predates per-chain execution delays, so only the global one is read.
    function _findEoa(bytes32 _role, bytes32 _alsoRole) internal view returns (address) {
        uint256 count = validatorTimelock.getRoleMemberCount(address(chain), _role);
        for (uint256 i = 0; i < count; ++i) {
            address member = validatorTimelock.getRoleMember(address(chain), _role, i);
            if (
                member.code.length == 0 &&
                (_alsoRole == bytes32(0) || validatorTimelock.hasRole(address(chain), _alsoRole, member))
            ) {
                return member;
            }
        }
        revert("no EOA holds the validator roles");
    }

    /// @dev Log 5: the L2 rollup DA validator's output for this calldata DA input.
    function _daOutputHash() internal pure returns (bytes32) {
        bytes32[] memory linearHashes = new bytes32[](CALLDATA_BLOBS);
        linearHashes[0] = BLOB_LINEAR_HASH;
        return
            Utils.constructRollupL2DAValidatorOutputHash(
                STATE_DIFF_HASH,
                EMPTY_STRING_KECCAK,
                CALLDATA_BLOBS,
                linearHashes
            );
    }

    function _setLog(bytes[] memory _logs, address _sender, SystemLogKey _key, bytes32 _value) internal pure {
        _logs[uint256(_key)] = Utils.constructL2Log(true, _sender, uint256(_key), _value);
    }

    function _stateRoot(uint256 _batchNumber) internal pure returns (bytes32) {
        return keccak256(abi.encode("v34 fork test: state root", _batchNumber));
    }

    function _l2LogsRoot(uint256 _batchNumber) internal pure returns (bytes32) {
        return keccak256(abi.encode("v34 fork test: L2 logs root", _batchNumber));
    }
}
