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
    IExecutor,
    SystemLogKey,
    TOTAL_BLOBS_IN_COMMITMENT
} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    BatchHashMismatch,
    CanOnlyProcessOneBatch,
    InvalidPublicInputsLength,
    VerifiedBatchesExceedsCommittedBatches
} from "contracts/common/L1ContractErrors.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
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

/// @notice Reports the size of the public input array the Executor handed the verifier.
/// @dev The value alone cannot distinguish a one-word array from a two-word one whose first word is
/// the same, which is exactly the confusion the `!= 0` sentinel prevents.
contract PublicInputCountRevealingVerifier is IVerifier {
    error RevealedPublicInputCount(uint256 count);

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external pure returns (bool) {
        revert RevealedPublicInputCount(_publicInputs.length);
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}

contract ProvingTest is ExecutorTest {
    bytes32 l2DAValidatorOutputHash;
    bytes32 airbenderHeapHash;
    bytes32 committedStateDiffHash;
    bytes32 committedBlobLinearHash;
    bytes32[] blobVersionedHashes;
    bytes operatorDAInput;

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

        // Commit with Airbender data, so the batch carries the sibling commitment and the prove
        // path builds the `[boojum, airbender]` pair. Suites that leave this zero stay Boojum-only.
        airbenderHeapHash = Utils.randomBytes32("airbenderBootloaderHeapHash");
        newCommitBatchInfo.airbenderBootloaderHeapHash = airbenderHeapHash;
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
            commitment: entries[EVENT_INDEX].topics[3],
            airbenderCommitment: _committedAirbenderCommitment()
        });
    }

    /// The Airbender-shape commitment the Committer produced for the batch just committed.
    function _committedAirbenderCommitment() internal view returns (bytes32) {
        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobHashes[0] = committedBlobLinearHash;
        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobCommitments[0] = Utils.defaultBlobOpeningCommitment(blobVersionedHashes[0]);
        return
            Utils.createAirbenderBatchCommitment(
                newCommitBatchInfo,
                committedStateDiffHash,
                blobCommitments,
                blobHashes
            );
    }

    function setUpCommitBatch() public {
        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        committedStateDiffHash = uncompressedStateDiffHash;
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");
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

    /// Era proves one batch per call, unconditionally. Making this depend on the Airbender lane let
    /// two Boojum-only batches produce a two-entry array that the gate reads as a (Boojum,
    /// Airbender) pair, routing the second batch's Boojum transition hash to the Airbender lane —
    /// so each batch settled on one lane, or on none with Airbender masked off.
    function test_eraProvesOneBatchPerCall() public {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](2);
        batches[0] = newStoredBatchInfo;
        batches[1] = newStoredBatchInfo;
        batches[1].batchNumber = 2;

        (uint256 from, uint256 to, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            _gateProof()
        );

        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, proveData);
    }

    /// A batch committed without a heap hash carries no Airbender commitment, so the Executor emits
    /// the Boojum word alone. Dropping the `!= 0` sentinel would make it emit a pair whose second
    /// word is zero.
    ///
    /// @dev Observed at the chain's verifier rather than behind the gate: the gate slices one word
    /// per lane, so no lane can see how many the Executor actually built.
    function test_batchWithoutAirbenderDataEmitsOnePublicInput() public {
        IExecutor.StoredBatchInfo memory laneOff = newStoredBatchInfo;
        laneOff.airbenderCommitment = bytes32(0);
        vm.store(address(executor), keccak256(abi.encode(uint256(1), uint256(14))), keccak256(abi.encode(laneOff)));

        vm.etch(getters.getVerifier(), address(new PublicInputCountRevealingVerifier()).code);

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputCountRevealingVerifier.RevealedPublicInputCount.selector, uint256(1))
        );
        _proveWithPrev(genesisStoredBatchInfo, _gateProof(), laneOff);
    }

    /// The mirror: a batch that does carry one makes the Executor build the pair.
    function test_batchWithAirbenderDataEmitsTwoPublicInputs() public {
        vm.etch(getters.getVerifier(), address(new PublicInputCountRevealingVerifier()).code);

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputCountRevealingVerifier.RevealedPublicInputCount.selector, uint256(2))
        );
        _proveWith(_gateProof());
    }

    function _installGate(IVerifier _boojum, IVerifier _airbender) internal {
        EraMultiProofVerifier gate = new EraMultiProofVerifier(_boojum, _airbender);
        vm.etch(getters.getVerifier(), address(gate).code);
    }

    function _gateProof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;
    }

    /// The value the Airbender lane receives. Transposing the operands of `keccak(prev | curr)`, or
    /// routing the Boojum word here, fails this.
    function test_airbenderLaneReceivesItsOwnTransitionHash() public {
        _installGate(IVerifier(address(new AcceptingLane())), IVerifier(address(new PublicInputRevealingVerifier())));

        // The genesis predecessor carries no Airbender commitment, so the chain seeds from its
        // Boojum commitment — which is authenticated and openable by the guest.
        uint256 expected = uint256(
            keccak256(abi.encodePacked(genesisStoredBatchInfo.commitment, newStoredBatchInfo.airbenderCommitment))
        );

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(0))
        );
        _proveWith(_gateProof());
    }

    /// The Boojum lane's word under the pair, which every other lane test accepts blindly. A bug
    /// feeding it the Airbender word would leave the Boojum proof unbound to the real batch chain.
    function test_boojumLaneReceivesTheStoredCommitmentTransitionHash() public {
        _installGate(IVerifier(address(new PublicInputRevealingVerifier())), IVerifier(address(new AcceptingLane())));

        uint256 expected = uint256(
            keccak256(abi.encodePacked(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment))
        );

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(1))
        );
        _proveWith(_gateProof());
    }

    /// A predecessor that does carry an Airbender commitment is used in preference to its Boojum
    /// one, so the seed rule applies only where there is nothing to chain to.
    function test_seedIsUsedOnlyWhenThePredecessorHasNoAirbenderCommitment() public {
        _installGate(IVerifier(address(new AcceptingLane())), IVerifier(address(new PublicInputRevealingVerifier())));

        IExecutor.StoredBatchInfo memory prev = genesisStoredBatchInfo;
        prev.airbenderCommitment = Utils.randomBytes32("predecessorAirbenderCommitment");
        vm.store(address(executor), keccak256(abi.encode(uint256(0), uint256(14))), keccak256(abi.encode(prev)));

        uint256 expected = uint256(
            keccak256(abi.encodePacked(prev.airbenderCommitment, newStoredBatchInfo.airbenderCommitment))
        );

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(0))
        );
        _proveWithPrev(prev, _gateProof());
    }

    /// A batch committed before the lane existed authenticates against the pre-Airbender hash form,
    /// which does not cover `airbenderCommitment`. Its lane must stay off rather than trust a field
    /// nothing bound — otherwise an operator could pair a Boojum proof of one batch with an
    /// Airbender proof of another.
    function test_preAirbenderBatchProvesBoojumOnly() public {
        _installGate(IVerifier(address(new PublicInputRevealingVerifier())), IVerifier(address(new AcceptingLane())));

        // Re-point the stored entry at the pre-Airbender form of the same batch.
        IExecutor.PreAirbenderStoredBatchInfo memory preAirbender = IExecutor.PreAirbenderStoredBatchInfo({
            batchNumber: newStoredBatchInfo.batchNumber,
            batchHash: newStoredBatchInfo.batchHash,
            indexRepeatedStorageChanges: newStoredBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newStoredBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newStoredBatchInfo.priorityOperationsHash,
            dependencyRootsRollingHash: newStoredBatchInfo.dependencyRootsRollingHash,
            l2LogsTreeRoot: newStoredBatchInfo.l2LogsTreeRoot,
            timestamp: newStoredBatchInfo.timestamp,
            commitment: newStoredBatchInfo.commitment
        });
        vm.store(
            address(executor),
            keccak256(abi.encode(uint256(1), uint256(14))),
            keccak256(abi.encode(preAirbender))
        );

        // One public input, so the gate refuses it — the lane is off for this batch.
        vm.expectRevert(InvalidPublicInputsLength.selector);
        _proveWith(_gateProof());
    }

    function _proveWithPrev(IExecutor.StoredBatchInfo memory _prev, uint256[] memory _proof) internal {
        _proveWithPrev(_prev, _proof, newStoredBatchInfo);
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
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            _proof
        );
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
