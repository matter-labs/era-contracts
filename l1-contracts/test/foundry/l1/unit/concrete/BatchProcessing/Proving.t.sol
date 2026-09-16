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
    bytes32 committedStateDiffHash;
    bytes32 committedBlobLinearHash;
    bytes32[] blobVersionedHashes;
    bytes operatorDAInput;

    function setUp() public {
        setUpCommitBatch();

        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        newStoredBatchInfo = _commitBatch(genesisStoredBatchInfo, 1);
    }

    /// Commits one batch on top of `_prev`, returning what the chain stored for it.
    function _commitBatch(
        IExecutor.StoredBatchInfo memory _prev,
        uint64 _batchNumber
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        currentTimestamp = block.timestamp;

        bytes[] memory logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        logs[uint256(SystemLogKey.PREV_BATCH_HASH_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            _prev.batchHash
        );

        newCommitBatchInfo.batchNumber = _batchNumber;
        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.systemLogs = Utils.encodePacked(logs);
        newCommitBatchInfo.operatorDAInput = operatorDAInput;
        // A distinct state root per batch — `randomBytes32` mixes in `block.timestamp`, which the
        // warp at the end of this helper has already moved on.
        newCommitBatchInfo.newStateRoot = Utils.randomBytes32("newStateRoot");

        CommitBatchInfo[] memory commitBatchInfoArray = new CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            _prev,
            commitBatchInfoArray
        );
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        stored = IExecutor.StoredBatchInfo({
            batchNumber: _batchNumber,
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
                committedStateDiffHash,
                committedBlobLinearHash,
                blobVersionedHashes[0]
            )
        });

        // Batches must not share a timestamp, so the next one lands strictly later.
        vm.warp(block.timestamp + 1);
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

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(genesisStoredBatchInfo)),
                keccak256(abi.encode(wrongPreviousStoredBatchInfo))
            )
        );
        _proveWithPrev(wrongPreviousStoredBatchInfo, proofInput, newStoredBatchInfo);
    }

    function test_RevertWhen_ProvingWithWrongCommittedBlock() public {
        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.batchNumber = 10; // Correct is 1

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(newStoredBatchInfo)),
                keccak256(abi.encode(wrongNewStoredBatchInfo))
            )
        );
        _proveWithPrev(genesisStoredBatchInfo, proofInput, wrongNewStoredBatchInfo);
    }

    /// The stored hash covers `airbenderCommitment`, so the proved batch cannot be paired with an
    /// Airbender commitment the commit did not produce.
    function test_RevertWhen_ProvingWithWrongAirbenderCommitment() public {
        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.airbenderCommitment = Utils.randomBytes32("forgedAirbenderCommitment");

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(newStoredBatchInfo)),
                keccak256(abi.encode(wrongNewStoredBatchInfo))
            )
        );
        _proveWithPrev(genesisStoredBatchInfo, proofInput, wrongNewStoredBatchInfo);
    }

    /// Every Era batch carries an Airbender commitment, so the Blake2s heap hash it is built from is
    /// required. Refused at commit rather than left to fail at prove.
    function test_RevertWhen_CommittingWithoutAirbenderHeapHash() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        // The batch `setUp` committed, minus the heap hash, is otherwise a valid commit on genesis.
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

    // ============ Public inputs handed to the verifier ============

    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    function test_executorEmitsTheShiftedTransitionHash() public {
        vm.etch(getters.getVerifier(), address(new PublicInputRevealingVerifier()).code);

        uint256 expected = _publicInput(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment);

        uint256[] memory proof = new uint256[](2);
        proof[0] = PLONK_VERIFICATION_TYPE;
        proof[1] = 0xdeadbeef;

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputRevealingVerifier.RevealedPublicInput.selector,
                expected,
                PLONK_VERIFICATION_TYPE
            )
        );
        _proveWith(proof);
    }

    /// One public input per proof system, always. The verifier slices one word per system, so the
    /// count is observed at the chain's verifier rather than behind it.
    function test_executorEmitsOnePublicInputPerProofSystem() public {
        vm.etch(getters.getVerifier(), address(new PublicInputCountRevealingVerifier()).code);

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputCountRevealingVerifier.RevealedPublicInputCount.selector, uint256(2))
        );
        _proveWith(_multiProof());
    }

    /// Era proves one batch per call, unconditionally.
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

    /// End-to-end through a real diamond: the Executor calls the multi-proof verifier, which reads the
    /// kill switch back off the chain's own Getters facet. The stubs in the verifier's own suite cannot
    /// catch a missing `disabledProofSystems` selector in the production facet cut; this can.
    function test_multiProofVerifierReadsDisabledSystemsFromTheChain() public {
        _installVerifier(IVerifier(address(new AcceptingVerifier())), IVerifier(address(new RejectingVerifier())));

        // Both required by default, and the Airbender verifier rejects, so the batch must not settle.
        vm.expectRevert(AirbenderVerificationFailed.selector);
        _proveWith(_multiProof());

        // With Airbender switched off by the chain admin, the same batch settles on Boojum alone.
        vm.prank(owner);
        IAdmin(address(executor)).setProofSystemStatus(ProofSystem.Airbender, false);
        _proveWith(_multiProof());
        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    /// Each proof system receives its own transition hash, and the batch settles only if both accept.
    /// Transposing the operands of `keccak(prev | curr)`, or routing a word to the wrong system, fails
    /// this.
    function test_bothProofSystemsReceiveTheirOwnTransitionHash() public {
        uint256 expectedBoojum = _publicInput(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment);
        uint256 expectedAirbender = _publicInput(
            genesisStoredBatchInfo.commitment,
            newStoredBatchInfo.airbenderCommitment
        );
        _installVerifier(
            IVerifier(address(new ExpectingVerifier(expectedBoojum))),
            IVerifier(address(new ExpectingVerifier(expectedAirbender)))
        );

        _proveWith(_multiProof());

        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    /// The Airbender input chains from the predecessor's Boojum commitment, not from its Airbender
    /// one. The guest opens a Boojum-shaped predecessor the way the Boojum scheduler opens its own,
    /// so every predecessor — genesis and pre-upgrade batches included — is an ordinary one.
    function test_airbenderInputChainsFromThePredecessorBoojumCommitment() public {
        // Both fields non-zero and distinct, so chaining from the wrong one is visible.
        IExecutor.StoredBatchInfo memory prev = genesisStoredBatchInfo;
        prev.commitment = Utils.randomBytes32("predecessorBoojumCommitment");
        prev.airbenderCommitment = Utils.randomBytes32("predecessorAirbenderCommitment");
        utilsFacet.util_setStoredBatchHashes(0, keccak256(abi.encode(prev)));

        _installVerifier(
            IVerifier(address(new AcceptingVerifier())),
            IVerifier(address(new PublicInputRevealingVerifier()))
        );

        uint256 expected = _publicInput(prev.commitment, newStoredBatchInfo.airbenderCommitment);
        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(0))
        );
        _proveWithPrev(prev, _multiProof(), newStoredBatchInfo);
    }

    /// The Boojum word under the pair, which the other tests accept blindly. A bug feeding it the
    /// Airbender word would leave the Boojum proof unbound to the real batch chain.
    function test_boojumInputIsTheStoredCommitmentTransitionHash() public {
        _installVerifier(
            IVerifier(address(new PublicInputRevealingVerifier())),
            IVerifier(address(new AcceptingVerifier()))
        );

        uint256 expected = _publicInput(genesisStoredBatchInfo.commitment, newStoredBatchInfo.commitment);

        vm.expectRevert(
            abi.encodeWithSelector(PublicInputRevealingVerifier.RevealedPublicInput.selector, expected, uint256(1))
        );
        _proveWith(_multiProof());
    }

    /// The last batch committed before `airbenderCommitment` existed was stored without it, and it is
    /// the predecessor of the first batch proved after the upgrade.
    function test_preAirbenderPredecessorAuthenticates() public {
        utilsFacet.util_setStoredBatchHashes(0, keccak256(abi.encode(_preAirbenderForm(genesisStoredBatchInfo))));

        _proveWith(proofInput);

        assertEq(getters.getTotalBlocksVerified(), 1);
    }

    /// The proved batch itself must be stored under the current form: the older one does not cover
    /// `airbenderCommitment`, so accepting it would let the caller choose the Airbender input.
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
        // Immutables live in runtime code, so etching carries the two addresses with it.
        vm.etch(getters.getVerifier(), address(new EraMultiProofVerifier(_boojum, _airbender)).code);
    }

    /// `[type, nBoojum=1, boojum(1 word), airbender(44 words)]`, enough envelope for the stand-ins.
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

/// @notice A verifier that accepts only the public input it was constructed with, so a test asserting a
/// batch settled is also asserting each proof system saw the right transition hash.
contract ExpectingVerifier is IVerifier {
    uint256 internal immutable EXPECTED;

    constructor(uint256 _expected) {
        EXPECTED = _expected;
    }

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external view returns (bool) {
        return _publicInputs.length == 1 && _publicInputs[0] == EXPECTED;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}

contract AcceptingVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract RejectingVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return false;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}
