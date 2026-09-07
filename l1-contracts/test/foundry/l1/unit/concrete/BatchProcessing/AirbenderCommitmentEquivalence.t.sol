// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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
