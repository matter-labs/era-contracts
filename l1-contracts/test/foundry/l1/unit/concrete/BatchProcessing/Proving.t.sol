// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {EVENT_INDEX, L2_SYSTEM_CONTEXT_ADDRESS, Utils} from "../Utils/Utils.sol";

import {
    EMPTY_PREPUBLISHED_COMMITMENT,
    ExecutorTest,
    POINT_EVALUATION_PRECOMPILE_RESULT
} from "./_Executor_Shared.t.sol";

import {
    AIRBENDER_SNARK_PROOF_LENGTH,
    ERA_MULTI_PROOF_TYPE,
    POINT_EVALUATION_PRECOMPILE_ADDR,
    ProofSystem,
    PUBLIC_INPUT_SHIFT,
    TESTNET_COMMIT_TIMESTAMP_NOT_OLDER
} from "contracts/common/Config.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {StoredBatchHashing} from "contracts/state-transition/chain-deps/StoredBatchHashing.sol";
import {
    AirbenderCommitmentRequired,
    AirbenderVerificationFailed,
    BatchHashMismatch,
    CanOnlyProcessOneBatch,
    VerifiedBatchesExceedsCommittedBatches
} from "contracts/common/L1ContractErrors.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {
    ExpectingVerifier,
    RevealingVerifier,
    StubVerifier
} from "foundry-test/l1/unit/concrete/state-transition/verifiers/VerifierStubs.sol";

contract ProvingTest is ExecutorTest {
    bytes32 l2DAValidatorOutputHash;
    bytes32 uncompressedStateDiffHash;
    bytes32 blobLinearHash;
    bytes32[] blobVersionedHashes;
    bytes operatorDAInput;

    function setUp() public {
        setUpCommitBatch();

        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        newStoredBatchInfo = _commitBatch();
    }

    /// Commits batch 1 on top of genesis and returns what the chain stored for it.
    function _commitBatch() internal returns (IExecutor.StoredBatchInfo memory stored) {
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = _commitData(genesisStoredBatchInfo);

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        stored = IExecutor.StoredBatchInfo({
            batchNumber: 1,
            batchHash: entries[EVENT_INDEX].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: currentTimestamp,
            commitment: entries[EVENT_INDEX].topics[3],
            airbenderCommitment: Utils.airbenderCommitmentForSingleBlob(
                newCommitBatchInfo,
                uncompressedStateDiffHash,
                blobLinearHash,
                blobVersionedHashes[0]
            )
        });
    }

    /// Commit data for batch 1 on top of `_prev`.
    function _commitData(IExecutor.StoredBatchInfo memory _prev) internal returns (uint256, uint256, bytes memory) {
        bytes[] memory logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.systemLogs = Utils.encodePacked(logs);
        newCommitBatchInfo.operatorDAInput = operatorDAInput;

        CommitBatchInfo[] memory commitBatchInfoArray = new CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;
        return Utils.encodeCommitBatchesData(_prev, commitBatchInfoArray);
    }

    function setUpCommitBatch() public {
        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");
        blobLinearHash = blobsLinearHashes[0];

        operatorDAInput = abi.encodePacked(
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
    }

    // ============ Authentication ============

    function test_RevertWhen_ProvingWithWrongPreviousBlockData() public {
        IExecutor.StoredBatchInfo memory wrongPrev = genesisStoredBatchInfo;
        wrongPrev.batchNumber = 10; // Correct is 0

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(genesisStoredBatchInfo)),
                keccak256(abi.encode(wrongPrev))
            )
        );
        _proveWithPrev(wrongPrev, proofInput, newStoredBatchInfo);
    }

    function test_RevertWhen_ProvingWithWrongCommittedBlock() public {
        IExecutor.StoredBatchInfo memory wrongNew = newStoredBatchInfo;
        wrongNew.batchNumber = 10; // Correct is 1

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(newStoredBatchInfo)),
                keccak256(abi.encode(wrongNew))
            )
        );
        _proveWithPrev(genesisStoredBatchInfo, proofInput, wrongNew);
    }

    function test_RevertWhen_ProvingWithWrongAirbenderCommitment() public {
        IExecutor.StoredBatchInfo memory wrongNew = newStoredBatchInfo;
        wrongNew.airbenderCommitment = Utils.randomBytes32("forgedAirbenderCommitment");

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(newStoredBatchInfo)),
                keccak256(abi.encode(wrongNew))
            )
        );
        _proveWithPrev(genesisStoredBatchInfo, proofInput, wrongNew);
    }

    function test_RevertWhen_CommittingWithoutAirbenderHeapHash() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        CommitBatchInfo memory batch = newCommitBatchInfo;
        batch.airbenderBootloaderHeapHash = bytes32(0);
        CommitBatchInfo[] memory batches = new CommitBatchInfo[](1);
        batches[0] = batch;
        (uint256 from, uint256 to, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            batches
        );

        vm.blobhashes(blobVersionedHashes);
        vm.prank(validator);
        vm.expectRevert(AirbenderCommitmentRequired.selector);
        committer.commitBatchesSharedBridge(address(0), from, to, commitData);
    }

    function test_RevertWhen_ProvingRevertedBlockWithoutCommittingAgain() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        vm.expectRevert(VerifiedBatchesExceedsCommittedBatches.selector);
        _proveWith(proofInput);
    }

    function test_SuccessfulProve() public {
        _proveWith(proofInput);

        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    // For accurate measuring of gas usage via snapshot cheatcodes, isolation mode has to be enabled.
    /// forge-config: default.isolate = true
    function test_MeasureGas() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        validatorTimelock.proveBatchesSharedBridge(address(executor), proveBatchFrom, proveBatchTo, proveData);
        vm.snapshotGasLastCall("Executor", "prove");
    }

    // ============ Pre-Airbender predecessor ============

    function test_preAirbenderHashFormMatchesTheHistoricalEncoding() public pure {
        IExecutor.StoredBatchInfo memory batch = IExecutor.StoredBatchInfo({
            batchNumber: 7,
            batchHash: keccak256("batchHash"),
            indexRepeatedStorageChanges: 11,
            numberOfLayer1Txs: 13,
            priorityOperationsHash: keccak256("priorityOperationsHash"),
            dependencyRootsRollingHash: keccak256("dependencyRootsRollingHash"),
            l2LogsTreeRoot: keccak256("l2LogsTreeRoot"),
            timestamp: 17,
            commitment: keccak256("commitment"),
            airbenderCommitment: keccak256("airbenderCommitment")
        });

        bytes32 expected = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                uint64(7),
                keccak256("batchHash"),
                uint64(11),
                uint256(13),
                keccak256("priorityOperationsHash"),
                keccak256("dependencyRootsRollingHash"),
                keccak256("l2LogsTreeRoot"),
                uint256(17),
                keccak256("commitment")
            )
        );

        assertEq(StoredBatchHashing.hashPreAirbenderStoredBatchInfo(batch), expected);
        assertTrue(StoredBatchHashing.hashStoredBatchInfo(batch) != expected);
    }

    /// The last batch stored before `airbenderCommitment` existed is the predecessor of the first
    /// batch committed and proved after the upgrade; its Boojum commitment seeds the Airbender chain.
    function test_preAirbenderPredecessorAuthenticates() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);
        utilsFacet.util_setStoredBatchHashes(0, keccak256(abi.encode(_preAirbenderForm(genesisStoredBatchInfo))));

        newStoredBatchInfo = _commitBatch();
        _installVerifier(
            IVerifier(
                address(
                    new ExpectingVerifier(
                        _publicInput(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment)
                    )
                )
            ),
            IVerifier(
                address(
                    new ExpectingVerifier(
                        _publicInput(genesisStoredBatchInfo.commitment, newStoredBatchInfo.airbenderCommitment)
                    )
                )
            )
        );
        _proveWith(_multiProof());

        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    /// A pre-Airbender predecessor is passed with a zero `airbenderCommitment`: its stored hash does not cover the
    /// field, so any other value would be an unverified seed for the Airbender chain.
    function test_RevertWhen_PreAirbenderPredecessorCarriesAnAirbenderCommitment() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);
        bytes32 preAirbenderHash = keccak256(abi.encode(_preAirbenderForm(genesisStoredBatchInfo)));
        utilsFacet.util_setStoredBatchHashes(0, preAirbenderHash);

        IExecutor.StoredBatchInfo memory prev = genesisStoredBatchInfo;
        prev.airbenderCommitment = Utils.randomBytes32("predecessorAirbenderCommitment");
        bytes memory mismatch = abi.encodeWithSelector(
            BatchHashMismatch.selector,
            preAirbenderHash,
            keccak256(abi.encode(prev))
        );

        (uint256 from, uint256 to, bytes memory commitData) = _commitData(prev);
        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.expectRevert(mismatch);
        committer.commitBatchesSharedBridge(address(0), from, to, commitData);

        newStoredBatchInfo = _commitBatch();
        vm.expectRevert(mismatch);
        _proveWithPrev(prev, _multiProof(), newStoredBatchInfo);
    }

    /// Only a predecessor may match the pre-Airbender form; the proved batch must carry its Airbender commitment.
    function test_RevertWhen_ProvedBatchIsStoredUnderThePreAirbenderForm() public {
        bytes32 preAirbenderHash = keccak256(abi.encode(_preAirbenderForm(newStoredBatchInfo)));
        utilsFacet.util_setStoredBatchHashes(1, preAirbenderHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                preAirbenderHash,
                keccak256(abi.encode(newStoredBatchInfo))
            )
        );
        _proveWith(_multiProof());
    }

    // ============ Public inputs ============

    function test_executorPassesTwoPublicInputs() public {
        vm.etch(getters.getVerifier(), address(new RevealingVerifier()).code);

        vm.expectRevert(
            abi.encodeWithSelector(
                RevealingVerifier.Revealed.selector,
                _publicInput(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment),
                2,
                ERA_MULTI_PROOF_TYPE,
                2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH
            )
        );
        _proveWith(_multiProof());
    }

    function test_eraProvesOneBatchPerCall() public {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](2);
        batches[0] = newStoredBatchInfo;
        batches[1] = newStoredBatchInfo;
        batches[1].batchNumber = 2;

        (uint256 from, uint256 to, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            _multiProof()
        );

        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, proveData);
    }

    /// Each proof system receives its own transition hash, chained on its own commitments.
    function test_bothProofSystemsReceiveTheirOwnTransitionHash() public {
        IExecutor.StoredBatchInfo memory prev = genesisStoredBatchInfo;
        prev.commitment = Utils.randomBytes32("predecessorBoojumCommitment");
        prev.airbenderCommitment = Utils.randomBytes32("predecessorAirbenderCommitment");
        utilsFacet.util_setStoredBatchHashes(0, keccak256(abi.encode(prev)));

        _installVerifier(
            IVerifier(address(new ExpectingVerifier(_publicInput(prev.commitment, newStoredBatchInfo.commitment)))),
            IVerifier(
                address(
                    new ExpectingVerifier(
                        _publicInput(prev.airbenderCommitment, newStoredBatchInfo.airbenderCommitment)
                    )
                )
            )
        );

        _proveWithPrev(prev, _multiProof(), newStoredBatchInfo);

        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    /// Through the diamond: the verifier reads `disabledProofSystems` from the calling chain.
    function test_multiProofVerifierReadsDisabledSystemsFromTheChain() public {
        _installVerifier(
            IVerifier(address(new StubVerifier(true, bytes32(0)))),
            IVerifier(address(new StubVerifier(false, bytes32(0))))
        );

        vm.expectRevert(AirbenderVerificationFailed.selector);
        _proveWith(_multiProof());

        vm.prank(owner);
        IAdmin(address(executor)).setProofSystemStatus(ProofSystem.Airbender, false);
        _proveWith(_multiProof());
        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    // ============ Helpers ============

    function _preAirbenderForm(
        IExecutor.StoredBatchInfo memory _batch
    ) internal pure returns (IExecutor.PreAirbenderStoredBatchInfo memory) {
        return
            IExecutor.PreAirbenderStoredBatchInfo({
                batchNumber: _batch.batchNumber,
                batchHash: _batch.batchHash,
                indexRepeatedStorageChanges: _batch.indexRepeatedStorageChanges,
                numberOfLayer1Txs: _batch.numberOfLayer1Txs,
                priorityOperationsHash: _batch.priorityOperationsHash,
                dependencyRootsRollingHash: _batch.dependencyRootsRollingHash,
                l2LogsTreeRoot: _batch.l2LogsTreeRoot,
                timestamp: _batch.timestamp,
                commitment: _batch.commitment
            });
    }

    /// `Executor._getBatchProofPublicInput`.
    function _publicInput(bytes32 _prevCommitment, bytes32 _commitment) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_prevCommitment, _commitment))) >> PUBLIC_INPUT_SHIFT;
    }

    function _installVerifier(IVerifier _boojum, IVerifier _airbender) internal {
        vm.etch(getters.getVerifier(), address(new EraMultiProofVerifier(_boojum, _airbender)).code);
    }

    /// `[type, N=1, boojum(1 word), airbender(44 words)]`
    function _multiProof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;
    }

    function _proveWithPrev(
        IExecutor.StoredBatchInfo memory _prev,
        uint256[] memory _proof,
        IExecutor.StoredBatchInfo memory _proved
    ) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _proved;
        (uint256 from, uint256 to, bytes memory proveData) = Utils.encodeProveBatchesData(_prev, batches, _proof);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, proveData);
    }

    function _proveWith(uint256[] memory _proof) internal {
        _proveWithPrev(genesisStoredBatchInfo, _proof, newStoredBatchInfo);
    }
}
