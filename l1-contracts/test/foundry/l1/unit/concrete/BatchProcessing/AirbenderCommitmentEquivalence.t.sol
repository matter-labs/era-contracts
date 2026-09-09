// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CommitterProvingTest} from "contracts/dev-contracts/test/CommitterProvingTest.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {StoredBatchHashing} from "contracts/state-transition/chain-deps/StoredBatchHashing.sol";
import {AirbenderCommitmentRequired} from "contracts/common/L1ContractErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED, BOOJUM_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Pins the Airbender-shape batch commitment against values produced by the Rust
/// implementation the guest runs.
///
/// Vectors come from `post_gateway_test.json` in `eravm-airbender-verifier` — a real post-gateway
/// batch whose four commitment hashes are recorded with the inputs that produced them — via
/// `zksync_types::commitment::airbender_l1_equivalence_tests`, which first asserts the vendored Rust
/// implementation still reproduces the recorded hashes, then emits the Airbender-shape commitment
/// for the same batch and for an all-16-blob variant.
///
/// What that anchors: the pass-through hash, metadata hash, auxiliary output hash and stored
/// commitment come from a recorded real batch, so the layout and composition are pinned against an
/// external source. The Airbender commitment is the same composition with the two divergent words
/// substituted, so it functions as a regression lock on the substitution rather than as an
/// independent oracle. The generators are not committed in `eravm-airbender-verifier`, so the chain
/// of custody is not reproducible from this repo alone.
///
/// This is the check whose absence let the shared-public-input blocker through: the guest's
/// `test_proof_public_input_matches_l1_shift` pins only the shift and the wrapper packing, over
/// synthetic `prev`/`curr`, so nothing asserted that L1's commitment bytes equal the guest's.
contract AirbenderCommitmentEquivalenceTest is Test {
    uint256 internal constant TOTAL_BLOBS = 16;

    // --- The recorded batch --------------------------------------------------------------------
    uint64 internal constant ENUMERATION_INDEX = 212;
    bytes32 internal constant STATE_ROOT = 0x0332d2acc43785a44b2b84fc010372c8f3e4ff4d0ca5f312de142ffe74189500;
    bytes32 internal constant EXPECTED_PASS_THROUGH_DATA_HASH =
        0x756c1660f611302295f6a56a8f4b9d68f2ebf51f8278f225d6b7e64bb9364be0;

    bytes32 internal constant BOOTLOADER_CODE_HASH = 0x010008c753336bc8d1ddca235602b9f31d346412b2d463cd342899f7bfb73baf;
    bytes32 internal constant DEFAULT_AA_CODE_HASH = 0x0100055d760f11a3d737e7fd1816e600a4cd874a9f17f7a225d1f1c537c51a1e;
    bytes32 internal constant EXPECTED_METADATA_HASH =
        0xdb298fa55c75b134333cee0b39f77aea956553a1eb861a5777dc7a66ad7a55b9;

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

    // --- The same batch with all 16 blob slots populated ----------------------------------------
    bytes32 internal constant ALL_BLOBS_STORED_COMMITMENT =
        0xce388864ee2658a135fcd83bf6bc3f61ce22172cac9d645719f6040b516cc4e4;
    bytes32 internal constant ALL_BLOBS_AIRBENDER_COMMITMENT =
        0xf6ef17dadb3219a501704adaf7a8cf56b9d2eb787efa50bfefdcbdd17f9cc213;

    // --- A vector the production Committer can be fed directly -------------------------------
    // Every component is a value `_createBatchCommitment` takes verbatim, except the system logs,
    // which it hashes — so these pin the contract's own derivation rather than a copy of it.
    bytes internal constant CALLABLE_SYSTEM_LOGS = "equivalence-test-system-logs";
    bytes32 internal constant CALLABLE_STATE_DIFF_HASH =
        0xbabb276f2a3cc5e989b45d546bd4fe011e38b6871007c3bb2578022c15e2d061;
    bytes32 internal constant CALLABLE_STORED_HEAP_HASH =
        0x4b9346c9c57e30d3fd3d17736fbad5e97f684654796068b370cd4a4ee5de4aca;
    bytes32 internal constant CALLABLE_EVENTS_QUEUE_HASH =
        0x44812432df1531df1815bbb31b03e35099006b09195f0d29f17a5f256898c080;
    bytes32 internal constant CALLABLE_AIRBENDER_HEAP_HASH =
        0x4573e336e6fbc57669de3612287d906192449493f016be61605c173e608eb5bb;
    bytes32 internal constant CALLABLE_STORED_COMMITMENT =
        0x97b974572cf9cbe4faf546c0a76168c55e94ede51c57d14ee413b1b3c2cc5fb4;
    bytes32 internal constant CALLABLE_AIRBENDER_COMMITMENT =
        0x2848bf1052d20059f77e2e7dc64d3faa230b108f37bc0db7563eee8b274e7005;

    CommitterProvingTest internal committer;

    function setUp() public {
        committer = new CommitterProvingTest();
        // The recorded batch was built with the emulator hash equal to the default-AA hash, which is
        // what Rust substitutes for `None`.
        committer.setBatchMetaParameters(false, BOOTLOADER_CODE_HASH, DEFAULT_AA_CODE_HASH, DEFAULT_AA_CODE_HASH);
        committer.setDisabledProofSystems(0);
    }

    function _callableBatch() internal pure returns (CommitBatchInfo memory batch) {
        batch.batchNumber = 1;
        batch.indexRepeatedStorageChanges = ENUMERATION_INDEX;
        batch.newStateRoot = STATE_ROOT;
        batch.bootloaderHeapInitialContentsHash = CALLABLE_STORED_HEAP_HASH;
        batch.eventsQueueStateHash = CALLABLE_EVENTS_QUEUE_HASH;
        batch.airbenderBootloaderHeapHash = CALLABLE_AIRBENDER_HEAP_HASH;
        batch.systemLogs = CALLABLE_SYSTEM_LOGS;
    }

    function _callableBlobs() internal pure returns (bytes32[] memory commitments, bytes32[] memory hashes) {
        bytes32[] memory words = _allBlobWords();
        commitments = new bytes32[](TOTAL_BLOBS);
        hashes = new bytes32[](TOTAL_BLOBS);
        for (uint256 i = 0; i < TOTAL_BLOBS; ++i) {
            hashes[i] = words[i * 2];
            commitments[i] = words[i * 2 + 1];
        }
    }

    /// The production derivation, called directly, against the Rust vector. This is what ties the
    /// external oracle to `Committer` — the inline reconstructions below only pin the layout.
    function test_committerProducesTheRustAirbenderCommitment() public {
        (bytes32[] memory commitments, bytes32[] memory hashes) = _callableBlobs();

        assertEq(
            committer.createBatchCommitment(_callableBatch(), CALLABLE_STATE_DIFF_HASH, commitments, hashes),
            CALLABLE_STORED_COMMITMENT,
            "Committer's Boojum commitment diverges from Rust"
        );
        assertEq(
            committer.createAirbenderBatchCommitment(_callableBatch(), CALLABLE_STATE_DIFF_HASH, commitments, hashes),
            CALLABLE_AIRBENDER_COMMITMENT,
            "Committer's Airbender commitment diverges from the guest's"
        );
    }

    /// A chain running the gate needs Airbender data on every batch: without it the batch carries no
    /// Airbender commitment and could never be proved, so the commit is refused rather than the
    /// failure surfacing later as an unexplained verification error.
    function test_multiProofChainRequiresAirbenderData() public {
        (bytes32[] memory commitments, bytes32[] memory hashes) = _callableBlobs();
        CommitBatchInfo memory batch = _callableBatch();
        batch.airbenderBootloaderHeapHash = bytes32(0);

        vm.expectRevert(AirbenderCommitmentRequired.selector);
        committer.createAirbenderBatchCommitment(batch, CALLABLE_STATE_DIFF_HASH, commitments, hashes);
    }

    /// With Boojum masked, the two words only that lane reproduces are pinned to zero rather than
    /// carried as unverified operator input. Everything else in the commitment is shared with the
    /// Airbender one, so what remains is covered by the Airbender proof.
    function test_boojumDisabledZeroesItsOwnAuxWords() public {
        (bytes32[] memory commitments, bytes32[] memory hashes) = _callableBlobs();

        // The same batch, committed once with the lane required and once with it masked.
        committer.setDisabledProofSystems(0);
        bytes32 withBoojum = committer.createBatchCommitment(
            _callableBatch(),
            CALLABLE_STATE_DIFF_HASH,
            commitments,
            hashes
        );

        committer.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_DISABLED);
        bytes32 masked = committer.createBatchCommitment(
            _callableBatch(),
            CALLABLE_STATE_DIFF_HASH,
            commitments,
            hashes
        );
        assertTrue(withBoojum != masked, "masking Boojum must drop its two aux words from the commitment");

        // Zeroing must not collapse the two lanes onto one value: a single proof satisfying both
        // public inputs is exactly what the two-system requirement exists to prevent.
        bytes32 airbender = committer.createAirbenderBatchCommitment(
            _callableBatch(),
            CALLABLE_STATE_DIFF_HASH,
            commitments,
            hashes
        );
        assertTrue(masked != airbender, "the two commitments must stay distinct");
    }

    /// Disabling Boojum leaves the Airbender lane required, so the batch still carries an Airbender
    /// commitment. The Boojum commitment keeps being built either way — it is the base commitment
    /// `storedBatchHashes` authenticates and the lane's fallback seed, not something the mask gates.
    function test_boojumDisabledStillCommitsAirbenderData() public {
        committer.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_DISABLED);
        (bytes32[] memory commitments, bytes32[] memory hashes) = _callableBlobs();

        assertTrue(
            committer.createAirbenderBatchCommitment(_callableBatch(), CALLABLE_STATE_DIFF_HASH, commitments, hashes) !=
                bytes32(0),
            "an Airbender-only chain must still carry an Airbender commitment"
        );
    }

    /// With the lane masked the heap hash is ignored rather than rejected, so the commitment comes
    /// out zero even when the sequencer is still sending one. That is what lets the kill switch take
    /// effect without the sequencer having to change shape in the same block.
    function test_maskedLaneIgnoresAirbenderData() public {
        committer.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        (bytes32[] memory commitments, bytes32[] memory hashes) = _callableBlobs();

        assertEq(
            committer.createAirbenderBatchCommitment(_callableBatch(), CALLABLE_STATE_DIFF_HASH, commitments, hashes),
            bytes32(0),
            "a masked lane must produce no Airbender commitment"
        );
    }

    /// A chain that does not run the gate commits no Airbender commitment at all.
    function test_singleProofChainCommitsNoAirbenderCommitment() public {
        committer.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        (bytes32[] memory commitments, bytes32[] memory hashes) = _callableBlobs();
        CommitBatchInfo memory batch = _callableBatch();
        batch.airbenderBootloaderHeapHash = bytes32(0);

        assertEq(
            committer.createAirbenderBatchCommitment(batch, CALLABLE_STATE_DIFF_HASH, commitments, hashes),
            bytes32(0),
            "a single-proof chain must carry no Airbender commitment"
        );
    }

    function _blobWords() internal pure returns (bytes32[] memory words) {
        words = new bytes32[](2 * TOTAL_BLOBS);
        words[0] = BLOB_0_LINEAR_HASH;
        words[1] = BLOB_0_COMMITMENT;
    }

    /// Mirrors the Rust emitter: slot `i` holds `keccak("L" ‖ i)` and `keccak("C" ‖ i)`. Distinct
    /// and asymmetric per slot, so transposing any pair — or any two slots — moves the hash.
    function _allBlobWords() internal pure returns (bytes32[] memory words) {
        words = new bytes32[](2 * TOTAL_BLOBS);
        for (uint8 i = 0; i < TOTAL_BLOBS; ++i) {
            words[uint256(i) * 2] = keccak256(abi.encodePacked(bytes1("L"), bytes1(i)));
            words[uint256(i) * 2 + 1] = keccak256(abi.encodePacked(bytes1("C"), bytes1(i)));
        }
    }

    /// Mirrors `Committer._batchAuxiliaryOutput`, with the two divergent words parameterised.
    function _auxiliaryOutputHash(
        bytes32 _heapHash,
        bytes32 _eventsQueueHash,
        bytes32[] memory _blobs
    ) internal pure returns (bytes32) {
        return
            keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(L2_TO_L1_LOGS_HASH, STATE_DIFF_HASH, _heapHash, _eventsQueueHash, _blobs)
            );
    }

    function _commitment(bytes32 _auxHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(EXPECTED_PASS_THROUGH_DATA_HASH, EXPECTED_METADATA_HASH, _auxHash));
    }

    /// The pre-Airbender hash form is the entire back-compat guarantee for batches committed before
    /// the upgrade: get its field order wrong and every one of them becomes permanently
    /// unauthenticatable. Pinned against an explicit encoding of the nine historical fields, with a
    /// distinct non-zero value in every slot so a transposition cannot hide.
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

        assertEq(
            StoredBatchHashing.hashPreAirbenderStoredBatchInfo(batch),
            expected,
            "pre-Airbender hash form diverges from the encoding it must reproduce"
        );
        assertTrue(
            StoredBatchHashing.hashStoredBatchInfo(batch) != expected,
            "the current form must cover airbenderCommitment and so differ"
        );
    }

    /// The pass-through encoding, which `Committer._batchPassThroughData` and the guest share.
    function test_passThroughDataMatchesRust() public pure {
        bytes32 derived = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(ENUMERATION_INDEX, STATE_ROOT, uint64(0), bytes32(0))
        );
        assertEq(derived, EXPECTED_PASS_THROUGH_DATA_HASH, "pass-through encoding diverges from Rust");
    }

    /// The metaparameters encoding. `L1BatchMetaParameters::to_bytes` substitutes
    /// `default_aa_code_hash` when `evm_emulator_code_hash` is `None`, while L1 emits
    /// `s.l2EvmEmulatorBytecodeHash` — so `None` and zero are NOT equivalent, which is why the guest
    /// forces `Some(unwrap_or_default())`. This fixture was recorded with `None`.
    function test_metaParametersNoneSerializesAsDefaultAA() public pure {
        bytes32 derived = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(false, BOOTLOADER_CODE_HASH, DEFAULT_AA_CODE_HASH, DEFAULT_AA_CODE_HASH)
        );
        assertEq(derived, EXPECTED_METADATA_HASH, "None must serialize as default_aa_code_hash");
    }

    /// The 36-word auxiliary output preimage: order, packing, and blob word interleaving.
    function test_auxiliaryOutputMatchesRust() public pure {
        assertEq(
            _auxiliaryOutputHash(STORED_HEAP_HASH, EVENTS_QUEUE_HASH, _blobWords()),
            EXPECTED_STORED_AUX_OUTPUT_HASH,
            "auxiliary output layout diverges from Rust"
        );
    }

    /// The three-layer composition `Committer._createBatchCommitment` performs.
    function test_commitmentCompositionMatchesRust() public pure {
        assertEq(
            _commitment(EXPECTED_STORED_AUX_OUTPUT_HASH),
            EXPECTED_STORED_COMMITMENT,
            "commitment composition diverges from Rust"
        );
    }

    /// The claim the design rests on: the same composition with the heap hash swapped and the events
    /// queue zeroed is exactly the commitment the guest computes.
    function test_airbenderCommitmentMatchesRust() public pure {
        assertEq(
            _commitment(_auxiliaryOutputHash(AIRBENDER_HEAP_HASH, bytes32(0), _blobWords())),
            EXPECTED_AIRBENDER_COMMITMENT,
            "Airbender commitment diverges from the guest's"
        );
    }

    /// The same over a batch with every blob slot populated, so the whole 32-word blob region and
    /// its interleaving are exercised rather than only slots 0 and 1.
    function test_airbenderCommitmentMatchesRustWithAllBlobSlots() public pure {
        assertEq(
            _commitment(_auxiliaryOutputHash(STORED_HEAP_HASH, EVENTS_QUEUE_HASH, _allBlobWords())),
            ALL_BLOBS_STORED_COMMITMENT,
            "stored commitment diverges over a full blob region"
        );
        assertEq(
            _commitment(_auxiliaryOutputHash(AIRBENDER_HEAP_HASH, bytes32(0), _allBlobWords())),
            ALL_BLOBS_AIRBENDER_COMMITMENT,
            "blob word interleaving diverges from the Rust implementation"
        );
    }
}
