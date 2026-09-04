// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {EVENT_INDEX, L2_SYSTEM_CONTEXT_ADDRESS, Utils} from "../Utils/Utils.sol";

import {
    EMPTY_PREPUBLISHED_COMMITMENT,
    ExecutorTest,
    POINT_EVALUATION_PRECOMPILE_RESULT
} from "./_Executor_Shared.t.sol";

import {POINT_EVALUATION_PRECOMPILE_ADDR, TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {
    AirbenderCommitmentWitness,
    AirbenderProofWitnesses,
    IExecutor,
    SystemLogKey,
    TOTAL_BLOBS_IN_COMMITMENT
} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    AirbenderBootstrapWitnessCountInvalid,
    AirbenderBootstrapWitnessNotExpected,
    AirbenderBootstrapWitnessRequired,
    AirbenderProvedWitnessCountInvalid,
    AirbenderWitnessNotSupportedOnZKsyncOS,
    CanOnlyProcessOneBatch,
    BatchHashMismatch,
    InvalidPublicInputsLength,
    VerifiedBatchesExceedsCommittedBatches
} from "contracts/common/L1ContractErrors.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {AirbenderCommitment} from "contracts/state-transition/libraries/AirbenderCommitment.sol";
import {
    AIRBENDER_PROOF_SYSTEM_DISABLED,
    AIRBENDER_SNARK_PROOF_LENGTH,
    ERA_MULTI_PROOF_TYPE
} from "contracts/common/Config.sol";

/// @notice Stand-in verifier that reports back which public input and proof type the Executor handed it.
/// @dev `IVerifier.verify` is `view`, so it cannot record to storage. Reverting with the values is the
/// only way to observe them, and it asserts on the real argument the Executor passed rather than on a mock.
contract PublicInputRevealingVerifier is IVerifier {
    error RevealedPublicInput(uint256 publicInput, uint256 proofType);

    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external pure returns (bool) {
        revert RevealedPublicInput(_publicInputs[0], _proof.length == 0 ? type(uint256).max : _proof[0]);
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}

contract ProvingTest is ExecutorTest {
    bytes32 l2DAValidatorOutputHash;
    bytes32[] blobVersionedHashes;
    bytes operatorDAInput;
    /// Kept from the commit so the Airbender witness can reopen the commitment it produced.
    bytes32 committedStateDiffHash;
    bytes32 committedBlobLinearHash;
    bytes committedSystemLogs;
    /// Built once in `setUp`: `Utils` is a deployed library, so constructing this inside a test
    /// would put a delegatecall between `vm.expectRevert` and the call actually under test.
    AirbenderCommitmentWitness internal provedWitness;

    function setUp() public {
        setUpCommitBatch();

        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        bytes memory l2Logs = Utils.encodePacked(correctL2Logs);

        committedSystemLogs = l2Logs;
        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.systemLogs = l2Logs;
        newCommitBatchInfo.operatorDAInput = operatorDAInput;

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
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 1,
            batchHash: entries[EVENT_INDEX].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: currentTimestamp,
            commitment: entries[EVENT_INDEX].topics[3]
        });

        _buildProvedWitness();
    }

    /// The witness that reopens the commitment `commitBatchesSharedBridge` just produced.
    function _buildProvedWitness() internal {
        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobHashes[0] = committedBlobLinearHash;
        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobCommitments[0] = Utils.defaultBlobOpeningCommitment(blobVersionedHashes[0]);

        provedWitness.metadataHash = Utils.batchMetadataHash();
        provedWitness.l2ToL1LogsHash = keccak256(committedSystemLogs);
        provedWitness.stateDiffHash = committedStateDiffHash;
        provedWitness.storedBootloaderHeapHash = newCommitBatchInfo.bootloaderHeapInitialContentsHash;
        provedWitness.eventsQueueStateHash = newCommitBatchInfo.eventsQueueStateHash;
        provedWitness.airbenderBootloaderHeapHash = Utils.randomBytes32("airbenderHeapHash");
        provedWitness.blobAuxOutputWords = Utils.blobAuxOutputWords(blobCommitments, blobHashes);
    }

    function setUpCommitBatch() public {
        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");
        committedStateDiffHash = uncompressedStateDiffHash;
        committedBlobLinearHash = blobsLinearHashes[0];

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

    function test_RevertWhen_ProvingWithWrongPreviousBlockData() public {
        IExecutor.StoredBatchInfo memory wrongPreviousStoredBatchInfo = genesisStoredBatchInfo;
        wrongPreviousStoredBatchInfo.batchNumber = 10; // Correct is 0

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(genesisStoredBatchInfo)),
                keccak256(abi.encode(wrongPreviousStoredBatchInfo))
            )
        );
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            wrongPreviousStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_ProvingWithWrongCommittedBlock() public {
        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.batchNumber = 10; // Correct is 1

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
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_ProvingRevertedBlockWithoutCommittingAgain() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);

        vm.expectRevert(VerifiedBatchesExceedsCommittedBatches.selector);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_SuccessfulProve() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 1);
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

    // ============ Public input handed to the verifier ============

    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    /// The Executor now emits the untruncated transition hash; `EraDualVerifier` and `AirbenderVerifier`
    /// each apply their own derivation on top. Shifting here would discard the low bits the Airbender
    /// binding consumes, so this pins the Executor to emitting the raw value.
    function test_executorEmitsUntruncatedTransitionHash() public {
        PublicInputRevealingVerifier revealer = new PublicInputRevealingVerifier();
        vm.etch(getters.getVerifier(), address(revealer).code);

        uint256 expectedRaw = uint256(
            keccak256(abi.encodePacked(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment))
        );

        uint256[] memory proof = new uint256[](2);
        proof[0] = PLONK_VERIFICATION_TYPE;
        proof[1] = 0xdeadbeef;

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proof
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputRevealingVerifier.RevealedPublicInput.selector,
                expectedRaw,
                PLONK_VERIFICATION_TYPE
            )
        );
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    /// End-to-end through a real diamond: the Executor calls the multi-proof gate, which reads the kill
    /// switch back off the chain's own Getters facet. The stubs in the verifier's own suite cannot catch a
    /// missing `disabledProofSystems` selector in the production facet cut; this can.
    function test_multiProofGateReadsDisabledSystemsFromTheChain() public {
        AcceptingLane boojumLane = new AcceptingLane();
        RejectingLane airbenderLane = new RejectingLane();
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(boojumLane)),
            IVerifier(address(airbenderLane))
        );
        // Immutables live in runtime code, so etching carries the two lane addresses with it.
        vm.etch(getters.getVerifier(), address(gate).code);

        // The genesis batch predates the lane, so seed its entry to take the recorded path. The
        // bootstrap path has its own coverage in the library suite.
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        uint256[] memory proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;

        // Both required by default, and the Airbender lane rejects, so the batch must not settle.
        vm.expectRevert(EraMultiProofVerifier.AirbenderVerificationFailed.selector);
        _proveWith(proof);

        // With Airbender switched off by the chain admin, the same batch settles on Boojum alone.
        vm.prank(owner);
        IAdmin(address(executor)).setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        _proveWith(proof);
        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    /// A verified batch's Airbender commitment is recorded, and recorded at the slot
    /// `ZKChainStorage.airbenderCommitments` declares: the write goes through the contract and the
    /// assertion reads it back with `vm.load` at the computed slot, against the value the library
    /// derives. A wrong slot, or a wrong value, fails here.
    function test_airbenderCommitmentIsRecordedAtTheDeclaredSlot() public {
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(new AcceptingLane())),
            IVerifier(address(new AcceptingLane()))
        );
        vm.etch(getters.getVerifier(), address(gate).code);
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        uint256[] memory proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;
        _proveWith(proof);

        assertEq(
            vm.load(address(executor), _airbenderCommitmentSlot(1)),
            AirbenderCommitment.deriveAirbenderCommitment(provedWitness, newStoredBatchInfo),
            "the verified batch's Airbender commitment must be recorded at the declared slot"
        );
    }

    /// A witness that does not reopen the batch's stored commitment is refused at the facet, not
    /// merely inside the library. The batch itself is genuine here, so `_checkBatchHashMismatch`
    /// passes and the authentication check is the only thing standing between a fabricated witness
    /// and a derived commitment.
    function test_witnessMustReopenTheStoredCommitment() public {
        _installAcceptingGate();
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;
        // Pinned by the authentication check, so perturbing it must be caught.
        airbender.proved[0].stateDiffHash = bytes32(uint256(provedWitness.stateDiffHash) ^ 1);

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectPartialRevert(AirbenderCommitment.CommitmentWitnessMismatch.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// A predecessor whose commitment can be opened, standing in for the genesis batch. Only its
    /// `batchNumber` differs from batch 1, and the pass-through hash does not include that, so
    /// `provedWitness` opens it too.
    function _openablePrev() internal view returns (IExecutor.StoredBatchInfo memory prev) {
        prev = newStoredBatchInfo;
        prev.batchNumber = 0;
    }

    /// @dev `_checkBatchHashMismatch` only compares `keccak(abi.encode(prevBatch))` against
    /// `storedBatchHashes[0]`, so pointing that entry at an openable struct is enough to reach the
    /// seeding path. The real genesis commitment is a config value with no supplyable preimage.
    function _installOpenablePrev() internal {
        vm.store(
            address(executor),
            keccak256(abi.encode(uint256(0), uint256(14))),
            keccak256(abi.encode(_openablePrev()))
        );
    }

    function _bootstrapWitnesses() internal view returns (AirbenderProofWitnesses memory airbender) {
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;
        airbender.bootstrap = new AirbenderCommitmentWitness[](1);
        airbender.bootstrap[0] = provedWitness;
    }

    /// The seeding path end to end: an unseeded chain derives `prev` from the bootstrap witness and
    /// hands the lane `keccak(seed | curr)`. Without this, replacing the whole bootstrap branch with
    /// a constant — never authenticating the witness at all — is invisible.
    function test_bootstrapSeedReachesTheAirbenderLane() public {
        _installOpenablePrev();
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(new AcceptingLane())),
            IVerifier(address(new PublicInputRevealingVerifier()))
        );
        vm.etch(getters.getVerifier(), address(gate).code);

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        uint256 expected = uint256(
            keccak256(
                abi.encodePacked(
                    AirbenderCommitment.deriveBootstrapCommitment(provedWitness, _openablePrev()),
                    AirbenderCommitment.deriveAirbenderCommitment(provedWitness, newStoredBatchInfo)
                )
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(0))
        );
        _proveWithPrev(_openablePrev(), batches, proof_(), _bootstrapWitnesses());
    }

    /// The bootstrap witness is authenticated like any other: a perturbed pinned word is refused.
    function test_bootstrapWitnessMustReopenItsBatch() public {
        _installOpenablePrev();
        _installAcceptingGate();

        AirbenderProofWitnesses memory airbender = _bootstrapWitnesses();
        airbender.bootstrap[0].l2ToL1LogsHash = bytes32(uint256(provedWitness.l2ToL1LogsHash) ^ 1);

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectPartialRevert(AirbenderCommitment.CommitmentWitnessMismatch.selector);
        _proveWithPrev(_openablePrev(), batches, proof_(), airbender);
    }

    /// Only the first bootstrap witness is read, so more than one would be silently ignored.
    function test_multipleBootstrapWitnessesAreRefused() public {
        _installOpenablePrev();
        _installAcceptingGate();

        AirbenderProofWitnesses memory airbender = _bootstrapWitnesses();
        airbender.bootstrap = new AirbenderCommitmentWitness[](2);
        airbender.bootstrap[0] = provedWitness;
        airbender.bootstrap[1] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectPartialRevert(AirbenderBootstrapWitnessCountInvalid.selector);
        _proveWithPrev(_openablePrev(), batches, proof_(), airbender);
    }

    /// A bootstrap witness with no proved witness reaches no derivation, so it must not be accepted
    /// and dropped.
    function test_bootstrapWitnessAloneIsRefused() public {
        _installAcceptingGate();

        AirbenderProofWitnesses memory airbender;
        airbender.bootstrap = new AirbenderCommitmentWitness[](1);
        airbender.bootstrap[0] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectRevert(AirbenderBootstrapWitnessNotExpected.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// The Boojum lane's word under the new encoding, which every other v2 test accepts blindly.
    /// A bug feeding it the Airbender word would leave the Boojum proof unbound to the real chain.
    function test_boojumLaneReceivesTheStoredCommitmentTransitionHash() public {
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(new PublicInputRevealingVerifier())),
            IVerifier(address(new AcceptingLane()))
        );
        vm.etch(getters.getVerifier(), address(gate).code);

        uint256 expected = uint256(
            keccak256(abi.encodePacked(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment))
        );

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(1))
        );
        _proveWith(_gateProof());
    }

    function _proveWithPrev(
        IExecutor.StoredBatchInfo memory _prev,
        IExecutor.StoredBatchInfo[] memory _batches,
        uint256[] memory _proof,
        AirbenderProofWitnesses memory _airbender
    ) internal {
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils
            .encodeProveBatchesDataWithAirbender(_prev, _batches, _proof, _airbender);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    /// The value the Airbender lane actually receives — not merely that two words were passed.
    /// Asserts the recorded `prev` and the derived `curr` in that order, so transposing the operands
    /// of `keccak(prev | curr)`, or routing the Boojum word to this lane, fails here.
    function test_airbenderLaneReceivesTheChainedTransitionHash() public {
        bytes32 seed = Utils.randomBytes32("seededGenesisAirbender");
        vm.store(address(executor), _airbenderCommitmentSlot(0), seed);

        // Boojum accepts; the Airbender lane reports back exactly what it was handed.
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(new AcceptingLane())),
            IVerifier(address(new PublicInputRevealingVerifier()))
        );
        vm.etch(getters.getVerifier(), address(gate).code);

        bytes32 currentAirbenderCommitment = AirbenderCommitment.deriveAirbenderCommitment(
            provedWitness,
            newStoredBatchInfo
        );
        uint256 expected = uint256(keccak256(abi.encodePacked(seed, currentAirbenderCommitment)));

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(0))
        );
        _proveWith(_gateProof());
    }

    /// A batch number is reused after `_revertBatches`, so an entry recorded for a batch that is
    /// later reverted must not be readable as the predecessor of whatever replaces it — otherwise
    /// the replacement's successor is handed a `prev` no proof can satisfy, with no way to clear it.
    ///
    /// @dev Re-committing a batch overwrites its `storedBatchHashes` entry; that overwrite is what
    /// is simulated here. `storedBatchHashes` is slot 14 per its declaration — if that were wrong
    /// the lookup would be unchanged and the assertion would fail, so this self-checks.
    function test_revertedBatchCommitmentIsNotReadBackForItsReplacement() public {
        _installAcceptingGate();
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));
        _proveWith(_gateProof());

        assertTrue(getters.airbenderCommitment(1) != bytes32(0), "the verified batch must be recorded");

        vm.store(
            address(executor),
            keccak256(abi.encode(uint256(1), uint256(14))),
            Utils.randomBytes32("replacementBatchOne")
        );

        assertEq(
            getters.airbenderCommitment(1),
            bytes32(0),
            "a replacement batch must not inherit the reverted batch's Airbender commitment"
        );
    }

    /// Only the first proved-batch witness is ever read, so more than one would be accepted and
    /// silently ignored.
    function test_multipleProvedWitnessesAreRefused() public {
        _installAcceptingGate();
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](2);
        airbender.proved[0] = provedWitness;
        airbender.proved[1] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectPartialRevert(AirbenderProvedWitnessCountInvalid.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// Era proves one batch per call. The guard moved out of `_verifyProof` when the public input
    /// array stopped being one entry per batch, so it needs coverage in its new home.
    function test_oneBatchPerProveIsEnforced() public {
        _installAcceptingGate();
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](2);
        batches[0] = newStoredBatchInfo;
        batches[1] = newStoredBatchInfo;
        batches[1].batchNumber = 2;

        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// The lane's chain only holds values the lane itself established. With Airbender switched off
    /// the gate verifies nothing against the derived commitment, so it must not be recorded — the
    /// next transition after the lane comes back seeds afresh instead.
    ///
    /// @dev The companion positive case is `test_airbenderCommitmentIsRecordedAtTheDeclaredSlot`;
    /// on its own this assertion would also hold if the slot were wrong, since a wrong slot reads
    /// zero too.
    function test_airbenderCommitmentNotRecordedWhenTheLaneIsDisabled() public {
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(new AcceptingLane())),
            IVerifier(address(new AcceptingLane()))
        );
        vm.etch(getters.getVerifier(), address(gate).code);
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        uint256[] memory proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;

        vm.prank(owner);
        IAdmin(address(executor)).setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        _proveWith(proof);

        assertEq(getters.getTotalBlocksVerified(), 1, "the batch settles on Boojum alone");
        assertEq(
            vm.load(address(executor), _airbenderCommitmentSlot(1)),
            bytes32(0),
            "a batch the Airbender lane never verified must not enter its chain"
        );
    }

    /// An unseeded chain refuses the transition unless it carries a witness for its predecessor.
    ///
    /// @dev The matching success case is `test_bootstrapSeedReachesTheAirbenderLane`, which points
    /// `storedBatchHashes[0]` at an openable predecessor. The production constraint is narrower than
    /// an earlier version of this comment claimed: a real chain's genesis commitment is a config
    /// value with no supplyable preimage, so seeding works when the lane is enabled on a live chain
    /// — where `prev` is a batch the chain itself committed — but not for one whose first ever
    /// proved batch is batch 1.
    function test_bootstrapWitnessIsRequiredWhenTheChainIsUnseeded() public {
        _installAcceptingGate();

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectRevert(AirbenderBootstrapWitnessRequired.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// A bootstrap witness for a predecessor whose commitment is already recorded would be ignored,
    /// so it is refused rather than silently dropped.
    function test_bootstrapWitnessRefusedOnceTheChainIsSeeded() public {
        _installAcceptingGate();
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;
        airbender.bootstrap = new AirbenderCommitmentWitness[](1);
        airbender.bootstrap[0] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectRevert(AirbenderBootstrapWitnessNotExpected.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// The witness must be opened against a batch the chain has stored, not one the caller invented.
    /// `_checkBatchHashMismatch` runs first, so a fabricated `StoredBatchInfo` never reaches the
    /// authentication check.
    function test_unstoredBatchIsRejectedBeforeTheWitnessIsOpened() public {
        _installAcceptingGate();
        vm.store(address(executor), _airbenderCommitmentSlot(0), Utils.randomBytes32("seededGenesisAirbender"));

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;
        batches[0].commitment = Utils.randomBytes32("fabricatedCommitment");

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;

        vm.expectPartialRevert(BatchHashMismatch.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// ZKsync OS chains have no Airbender lane, and their stored `commitment` is a batch output hash
    /// with no such preimage, so the encoding is refused outright rather than failing obscurely
    /// inside the witness authentication.
    ///
    /// @dev `zksyncOS` is the low byte of the packed slot its declaration names; the rest of the
    /// word is preserved. If that slot were wrong the flag would not take and this would revert
    /// with something else, so the test self-checks.
    function test_airbenderWitnessRefusedOnZKsyncOSChain() public {
        _installAcceptingGate();

        uint256 zksyncOSSlot = 60;
        bytes32 packed = vm.load(address(executor), bytes32(zksyncOSSlot));
        vm.store(address(executor), bytes32(zksyncOSSlot), packed | bytes32(uint256(1)));

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        vm.expectRevert(AirbenderWitnessNotSupportedOnZKsyncOS.selector);
        _proveWithWitnesses(batches, proof_(), airbender);
    }

    /// The legacy encoding carries no witnesses, so it produces a one-word public input array that
    /// the gate refuses — the choice of encoding cannot be used to leave the lane unchecked.
    function test_legacyEncodingIsRefusedByTheGate() public {
        _installAcceptingGate();

        vm.expectRevert(InvalidPublicInputsLength.selector);
        _proveWithLegacyEncoding(proof_());
    }

    function _installAcceptingGate() internal {
        EraMultiProofVerifier gate = new EraMultiProofVerifier(
            IVerifier(address(new AcceptingLane())),
            IVerifier(address(new AcceptingLane()))
        );
        vm.etch(getters.getVerifier(), address(gate).code);
    }

    function _gateProof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;
    }

    function proof_() internal pure returns (uint256[] memory) {
        return _gateProof();
    }

    function _proveWithWitnesses(
        IExecutor.StoredBatchInfo[] memory _batches,
        uint256[] memory _proof,
        AirbenderProofWitnesses memory _airbender
    ) internal {
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils
            .encodeProveBatchesDataWithAirbender(genesisStoredBatchInfo, _batches, _proof, _airbender);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function _proveWithLegacyEncoding(uint256[] memory _proof) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            _proof
        );
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    /// @dev `ZKChainStorage.airbenderCommitments` — asserted rather than assumed by
    /// `test_airbenderCommitmentIsRecordedAtTheDeclaredSlot`.
    uint256 internal constant AIRBENDER_COMMITMENTS_SLOT = 69;

    /// @dev Keyed by the batch's stored hash, so a reverted batch's entry cannot be read back for
    /// whatever later occupies its number.
    function _airbenderCommitmentSlot(uint256 _batchNumber) internal view returns (bytes32) {
        return keccak256(abi.encode(getters.storedBatchHash(_batchNumber), AIRBENDER_COMMITMENTS_SLOT));
    }

    function _proveWith(uint256[] memory _proof) internal {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        AirbenderProofWitnesses memory airbender;
        airbender.proved = new AirbenderCommitmentWitness[](1);
        airbender.proved[0] = provedWitness;

        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils
            .encodeProveBatchesDataWithAirbender(genesisStoredBatchInfo, storedBatchInfoArray, _proof, airbender);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }
}

contract AcceptingLane is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract RejectingLane is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return false;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}
