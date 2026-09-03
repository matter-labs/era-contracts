// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AirbenderCommitmentWitness, IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {AirbenderCommitment} from "contracts/state-transition/libraries/AirbenderCommitment.sol";

/// @notice Pins the Solidity Airbender commitment derivation against values produced by the Rust
/// implementation the guest uses.
///
/// Vectors come from `post_gateway_test.json` in `eravm-airbender-verifier` — a real post-gateway
/// batch whose four commitment hashes are recorded with the inputs that produced them — via:
///
/// - `zksync_types::commitment::airbender_l1_equivalence_tests`, which first asserts the vendored
///   Rust implementation still reproduces the recorded hashes, then emits the Airbender-shape
///   commitment for the same batch and for an all-16-blob variant of it;
/// - `zksync_airbender_verifier`'s `tests/l1_derivation_fixture.rs`, which checks the pass-through
///   hash against the guest's own `compute_pass_through_data_hash`.
///
/// So every expected value here is produced by the code the guest actually runs, not re-derived.
///
/// This is the test whose absence let the shared-public-input blocker through: the guest's
/// `test_proof_public_input_matches_l1_shift` pins only the shift and the wrapper packing, over
/// synthetic `prev`/`curr`, so nothing asserted that L1's commitment bytes equal the guest's.
contract AirbenderCommitmentDerivationTest is Test {
    // --- Batch pass-through data -------------------------------------------------------------
    uint64 internal constant ENUMERATION_INDEX = 212;
    bytes32 internal constant STATE_ROOT = 0x0332d2acc43785a44b2b84fc010372c8f3e4ff4d0ca5f312de142ffe74189500;
    bytes32 internal constant EXPECTED_PASS_THROUGH_DATA_HASH =
        0x756c1660f611302295f6a56a8f4b9d68f2ebf51f8278f225d6b7e64bb9364be0;

    // --- Meta parameters ---------------------------------------------------------------------
    bytes32 internal constant BOOTLOADER_CODE_HASH = 0x010008c753336bc8d1ddca235602b9f31d346412b2d463cd342899f7bfb73baf;
    bytes32 internal constant DEFAULT_AA_CODE_HASH = 0x0100055d760f11a3d737e7fd1816e600a4cd874a9f17f7a225d1f1c537c51a1e;
    bytes32 internal constant EXPECTED_METADATA_HASH =
        0xdb298fa55c75b134333cee0b39f77aea956553a1eb861a5777dc7a66ad7a55b9;

    // --- Auxiliary output, as recorded (only blob slot 0 populated) ---------------------------
    bytes32 internal constant L2_TO_L1_LOGS_HASH = 0xe8460ce1ed47b77cfee3cadf803aa089c144c506ea2bdd358a6a38ff2c7bc8e3;
    bytes32 internal constant STATE_DIFF_HASH = 0xc83cac9cd98a4216cbc0d0830e63c4956e4a1c45c122ebbc88af7ea3b496c406;
    bytes32 internal constant STORED_HEAP_HASH = 0x97df88dcecbcd29b49773c042cdee7a44c57a741e64913fff5aa1b3484232f28;
    bytes32 internal constant EVENTS_QUEUE_HASH = 0xec82208c87a937d88768a0067b2a80f0525eca8288dad2cf96cf8bbe6a1aa565;
    bytes32 internal constant BLOB_0_LINEAR_HASH = 0xff4feb4bef9401731ab9db3626c2e015baa6880d7b1c4382d03b30da3a0fd75e;
    bytes32 internal constant BLOB_0_COMMITMENT = 0xf840cf3f6b7dc92729b2b9ef3b399e7b896d553b746362fe81c4eb911013570d;

    bytes32 internal constant EXPECTED_STORED_AUX_OUTPUT_HASH =
        0xcccf1ef8192054cb1b5fb668868ce4e069a695a1394b9486ebd3031cec12fe12;
    bytes32 internal constant EXPECTED_STORED_COMMITMENT =
        0xd6615c5447c817a320c69c6a5af12c472fd4d5bc2ef4de7806d40afe384ddc27;

    bytes32 internal constant AIRBENDER_HEAP_HASH = 0x35d519e586d0b30fb291b1ce24ce8ce0605af7f52c4bad1394febb63e387ed98;
    bytes32 internal constant EXPECTED_AIRBENDER_COMMITMENT =
        0xeb414bd21d1e5e39d8e169b9142b7e7eac72a3ebc5f2c6c43b85ca2f0f7272c7;
    /// Airbender shape (events queue zeroed) but keeping the committed Poseidon heap hash.
    bytes32 internal constant EXPECTED_BOOTSTRAP_COMMITMENT =
        0xf8df01f01da6cc9a7efb8a7210b4b8385e5b41ca806120b5b7860b4525288ce1;

    // --- The same batch with all 16 blob slots populated --------------------------------------
    // The recorded batch fills only slot 0, so on its own it cannot pin the
    // `[2i] = linearHash, [2i+1] = commitment` interleaving for any later slot.
    bytes32 internal constant ALL_BLOBS_STORED_COMMITMENT =
        0xce388864ee2658a135fcd83bf6bc3f61ce22172cac9d645719f6040b516cc4e4;
    bytes32 internal constant ALL_BLOBS_AIRBENDER_COMMITMENT =
        0xf6ef17dadb3219a501704adaf7a8cf56b9d2eb787efa50bfefdcbdd17f9cc213;

    // --- Fixture construction ------------------------------------------------------------------

    function _blobWords() internal pure returns (bytes32[] memory words) {
        words = new bytes32[](32);
        words[0] = BLOB_0_LINEAR_HASH;
        words[1] = BLOB_0_COMMITMENT;
    }

    /// Mirrors the Rust emitter: slot `i` holds `keccak("L" ‖ i)` and `keccak("C" ‖ i)`. Distinct
    /// and asymmetric per slot, so transposing any pair — or any two slots — moves the hash.
    function _allBlobWords() internal pure returns (bytes32[] memory words) {
        words = new bytes32[](32);
        for (uint8 i = 0; i < 16; ++i) {
            words[uint256(i) * 2] = keccak256(abi.encodePacked(bytes1("L"), bytes1(i)));
            words[uint256(i) * 2 + 1] = keccak256(abi.encodePacked(bytes1("C"), bytes1(i)));
        }
    }

    function _storedBatch(bytes32 _commitment) internal pure returns (IExecutor.StoredBatchInfo memory batch) {
        batch.batchNumber = 1;
        batch.batchHash = STATE_ROOT;
        batch.indexRepeatedStorageChanges = ENUMERATION_INDEX;
        batch.commitment = _commitment;
    }

    function _storedBatch() internal pure returns (IExecutor.StoredBatchInfo memory) {
        return _storedBatch(EXPECTED_STORED_COMMITMENT);
    }

    function _witness() internal pure returns (AirbenderCommitmentWitness memory witness) {
        witness = AirbenderCommitmentWitness({
            metadataHash: EXPECTED_METADATA_HASH,
            l2ToL1LogsHash: L2_TO_L1_LOGS_HASH,
            stateDiffHash: STATE_DIFF_HASH,
            storedBootloaderHeapHash: STORED_HEAP_HASH,
            eventsQueueStateHash: EVENTS_QUEUE_HASH,
            airbenderBootloaderHeapHash: AIRBENDER_HEAP_HASH,
            blobAuxOutputWords: _blobWords()
        });
    }

    /// External wrapper so the internal library function can be `vm.expectRevert`ed.
    function deriveExternal(
        AirbenderCommitmentWitness memory _w,
        IExecutor.StoredBatchInfo memory _b
    ) external pure returns (bytes32) {
        return AirbenderCommitment.deriveAirbenderCommitment(_w, _b);
    }

    // --- Equivalence with the Rust implementation ----------------------------------------------

    /// The pass-through data hash is derivable from `StoredBatchInfo` alone, so it is never taken
    /// from the witness and cannot be chosen by the operator. Pinned directly against the guest.
    function test_passThroughDataHashMatchesRust() public pure {
        assertEq(
            AirbenderCommitment.passThroughDataHash(_storedBatch()),
            EXPECTED_PASS_THROUGH_DATA_HASH,
            "pass-through data encoding diverges from the Rust implementation"
        );
    }

    /// The claim the whole design rests on: swapping the two divergent words in a preimage
    /// authenticated against the stored commitment yields exactly the commitment the guest computes.
    function test_derivedAirbenderCommitmentMatchesRust() public pure {
        assertEq(
            AirbenderCommitment.deriveAirbenderCommitment(_witness(), _storedBatch()),
            EXPECTED_AIRBENDER_COMMITMENT,
            "derived Airbender commitment diverges from the guest's"
        );
    }

    /// The same, over a batch with every blob slot populated, so the full 32-word blob region and
    /// its interleaving go through the library rather than only slots 0 and 1.
    function test_derivedAirbenderCommitmentMatchesRustWithAllBlobSlots() public pure {
        AirbenderCommitmentWitness memory w = _witness();
        w.blobAuxOutputWords = _allBlobWords();

        assertEq(
            AirbenderCommitment.deriveAirbenderCommitment(w, _storedBatch(ALL_BLOBS_STORED_COMMITMENT)),
            ALL_BLOBS_AIRBENDER_COMMITMENT,
            "blob word interleaving diverges from the Rust implementation"
        );
    }

    /// The seed for the first transition after the lane is enabled: Airbender shape, but with the
    /// heap hash the batch was actually committed with, because no Airbender proof ever ran on it.
    function test_bootstrapCommitmentMatchesRust() public pure {
        assertEq(
            AirbenderCommitment.deriveBootstrapCommitment(_witness(), _storedBatch()),
            EXPECTED_BOOTSTRAP_COMMITMENT,
            "bootstrap seed diverges from the Rust implementation"
        );
    }

    /// The seed is a pure function of the authenticated commitment: the one witness word the
    /// authentication leaves free is not read on this path, so an operator cannot steer it.
    function test_bootstrapIgnoresTheAirbenderHeapHash() public pure {
        AirbenderCommitmentWitness memory w = _witness();
        w.airbenderBootloaderHeapHash = bytes32(uint256(w.airbenderBootloaderHeapHash) ^ 1);

        assertEq(
            AirbenderCommitment.deriveBootstrapCommitment(w, _storedBatch()),
            EXPECTED_BOOTSTRAP_COMMITMENT,
            "the bootstrap seed must not depend on a word the authentication does not pin"
        );
    }

    /// The seed is not the batch's real Airbender commitment, and not its stored one either.
    function test_bootstrapIsDistinctFromBothCommitments() public pure {
        bytes32 seed = AirbenderCommitment.deriveBootstrapCommitment(_witness(), _storedBatch());
        assertTrue(seed != EXPECTED_AIRBENDER_COMMITMENT, "seed must differ from the Airbender commitment");
        assertTrue(seed != EXPECTED_STORED_COMMITMENT, "seed must differ from the stored commitment");
    }

    // --- Witness authentication ------------------------------------------------------------------

    /// The stored-shape commitment the library should derive for a given witness and pass-through
    /// hash. Used only to predict the revert arguments; its encoding is itself pinned to Rust by
    /// `test_fixture_auxiliaryOutputHashMatchesRust`.
    function _expectedDerived(
        AirbenderCommitmentWitness memory _w,
        bytes32 _passThroughDataHash
    ) internal pure returns (bytes32) {
        bytes32 aux = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(
                _w.l2ToL1LogsHash,
                _w.stateDiffHash,
                _w.storedBootloaderHeapHash,
                _w.eventsQueueStateHash,
                _w.blobAuxOutputWords
            )
        );
        return keccak256(abi.encode(_passThroughDataHash, _w.metadataHash, aux));
    }

    /// Asserts the exact error, including both arguments — not merely that the call reverted.
    function _expectMismatch(
        AirbenderCommitmentWitness memory _w,
        IExecutor.StoredBatchInfo memory _b,
        bytes32 _passThroughDataHash
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                AirbenderCommitment.CommitmentWitnessMismatch.selector,
                _b.commitment,
                _expectedDerived(_w, _passThroughDataHash)
            )
        );
        this.deriveExternal(_w, _b);
    }

    function _expectMismatch(AirbenderCommitmentWitness memory _w) internal {
        _expectMismatch(_w, _storedBatch(), EXPECTED_PASS_THROUGH_DATA_HASH);
    }

    function test_everyPinnedWitnessWordIsAuthenticated() public {
        AirbenderCommitmentWitness memory w;

        w = _witness();
        w.metadataHash = bytes32(uint256(w.metadataHash) ^ 1);
        _expectMismatch(w);

        w = _witness();
        w.l2ToL1LogsHash = bytes32(uint256(w.l2ToL1LogsHash) ^ 1);
        _expectMismatch(w);

        w = _witness();
        w.stateDiffHash = bytes32(uint256(w.stateDiffHash) ^ 1);
        _expectMismatch(w);

        w = _witness();
        w.storedBootloaderHeapHash = bytes32(uint256(w.storedBootloaderHeapHash) ^ 1);
        _expectMismatch(w);

        w = _witness();
        w.eventsQueueStateHash = bytes32(uint256(w.eventsQueueStateHash) ^ 1);
        _expectMismatch(w);
    }

    /// Every blob word is pinned, not just the two the recorded batch populates. The last slot and
    /// a middle one are covered explicitly because a library that truncated or ignored the tail
    /// would otherwise pass.
    function test_everyBlobWordIsAuthenticated() public {
        uint256[4] memory indices = [uint256(0), 1, 17, 31];

        for (uint256 i = 0; i < indices.length; ++i) {
            AirbenderCommitmentWitness memory w = _witness();
            w.blobAuxOutputWords = _allBlobWords();
            w.blobAuxOutputWords[indices[i]] = bytes32(uint256(w.blobAuxOutputWords[indices[i]]) ^ 1);

            _expectMismatch(w, _storedBatch(ALL_BLOBS_STORED_COMMITMENT), EXPECTED_PASS_THROUGH_DATA_HASH);
        }
    }

    /// The witness is bound to the batch through the derived pass-through hash, so a correct
    /// witness presented against a different batch must not authenticate.
    function test_witnessIsBoundToTheBatchPassThroughData() public {
        IExecutor.StoredBatchInfo memory b = _storedBatch();
        b.batchHash = bytes32(uint256(STATE_ROOT) ^ 1);
        _expectMismatch(_witness(), b, AirbenderCommitment.passThroughDataHash(b));

        b = _storedBatch();
        b.indexRepeatedStorageChanges = ENUMERATION_INDEX + 1;
        _expectMismatch(_witness(), b, AirbenderCommitment.passThroughDataHash(b));
    }

    /// The one word the authentication deliberately leaves free. Soundness for it comes from the
    /// guest constraining its heap hash to its actual execution, not from this check.
    function test_airbenderHeapHashIsNotPinned() public view {
        AirbenderCommitmentWitness memory w = _witness();
        w.airbenderBootloaderHeapHash = bytes32(uint256(w.airbenderBootloaderHeapHash) ^ 1);

        bytes32 derived = this.deriveExternal(w, _storedBatch());
        assertTrue(derived != EXPECTED_AIRBENDER_COMMITMENT, "a different heap hash must move the commitment");
    }

    /// Both directions. Too long is the one that would reintroduce packed-encoding ambiguity.
    function test_blobWordCountIsChecked() public {
        AirbenderCommitmentWitness memory w = _witness();

        w.blobAuxOutputWords = new bytes32[](31);
        vm.expectRevert(
            abi.encodeWithSelector(AirbenderCommitment.InvalidBlobAuxOutputLength.selector, uint256(31), uint256(32))
        );
        this.deriveExternal(w, _storedBatch());

        w.blobAuxOutputWords = new bytes32[](33);
        vm.expectRevert(
            abi.encodeWithSelector(AirbenderCommitment.InvalidBlobAuxOutputLength.selector, uint256(33), uint256(32))
        );
        this.deriveExternal(w, _storedBatch());
    }

    // --- Fixture self-consistency ----------------------------------------------------------------
    // These do not exercise the library. They pin the encodings the expectation helpers above rely
    // on, so a wrong oracle cannot make the authentication tests pass vacuously.

    function test_fixture_auxiliaryOutputHashMatchesRust() public pure {
        bytes32 auxHash = keccak256(
            abi.encodePacked(L2_TO_L1_LOGS_HASH, STATE_DIFF_HASH, STORED_HEAP_HASH, EVENTS_QUEUE_HASH, _blobWords())
        );
        assertEq(auxHash, EXPECTED_STORED_AUX_OUTPUT_HASH, "auxiliary output layout diverges from Rust");
    }

    function test_fixture_commitmentCompositionMatchesRust() public pure {
        bytes32 commitment = keccak256(
            abi.encode(EXPECTED_PASS_THROUGH_DATA_HASH, EXPECTED_METADATA_HASH, EXPECTED_STORED_AUX_OUTPUT_HASH)
        );
        assertEq(commitment, EXPECTED_STORED_COMMITMENT, "commitment composition diverges from Rust");
    }

    /// `L1BatchMetaParameters::to_bytes` substitutes `default_aa_code_hash` when
    /// `evm_emulator_code_hash` is `None`; L1's `_batchMetaParameters` emits
    /// `s.l2EvmEmulatorBytecodeHash`, which is `bytes32(0)` on an emulator-disabled chain. The two
    /// are therefore NOT equivalent, which is why the guest forces `Some(unwrap_or_default())`.
    ///
    /// This fixture was recorded with `None`, so L1 reproduces its metadata hash only with the
    /// emulator slot set to `default_aa_code_hash`. Pinned so the trap is visible rather than
    /// folklore — nothing on the Solidity side can detect the guest-side invariant regressing.
    function test_fixture_metaParametersNoneSerializesAsDefaultAA() public pure {
        bytes32 asRustSubstitutes = keccak256(
            abi.encodePacked(false, BOOTLOADER_CODE_HASH, DEFAULT_AA_CODE_HASH, DEFAULT_AA_CODE_HASH)
        );
        assertEq(asRustSubstitutes, EXPECTED_METADATA_HASH, "None must serialize as default_aa_code_hash");
    }
}
