// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IZiskSnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/IZiskSnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";

/// @notice Real-crypto anchor for the ZiSK verifier stack.
/// @dev A fixture holds a 768-byte BN254 PLONK SNARK plus the 576-byte public
///      values `programVK(32) || guest publics(512) || rootCVadcopFinal(32)`,
///      whose single public signal is `sha256(publicValues) % r`. The
///      guest-publics section is 64 little-endian u64 slots, one per guest
///      public; a guest public holds a 32-bit value, so each slot carries four
///      significant bytes and four zero pad bytes.
///
///      The BATCH fixture is the inner state-transition proof of batch 1, so
///      its wire bytes [0..32] hold the INNER programVK and its first eight
///      guest-public slots, bytes [32..96], the raw batch commitment. The
///      AGGREGATED fixture proves the whole range, so its wire bytes [0..32]
///      hold the AGGREGATOR programVK and its first eight slots the binding
///      digest `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`.
///
///      `ZiskVerifier.verify` rebuilds exactly those 576 aggregated bytes from
///      its own pins and the batch public inputs, so the aggregated fixture
///      drives the production path end to end: the reconstruction AND the real
///      pairing. MultiProofRangeVectorTest pins the same vector against a
///      signal stand-in, which is what lets it name the exact expected signal.
/// @dev Fixtures: ZiSK 1.3.0-alpha, guest ELFs reproduced from the pins in GPU run
///      https://github.com/matter-labs/zksync-os-zisk/actions/runs/36396740141.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte BN254 PLONK SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"220e3fab2445dd3a7d7cbe48835170342050bcb0a6e8f6f949e161ddedcd7ab82c013d07c52693df35ab497fb6717b067ad53685f7fa66874e817f4b056236a90e2711d3de09f9e1c4a10e56a369d4e99fdbd4613d2a14075ae3f1a078216dfe27c38c06f806107b1ba721862382897d57d7c7e8299f106e68338245970f77d1106bc82dcd61f7a207d3da2a01151d681cd02ea8469ebdb756e17a96c26d16c01b0e657c996377137029d689a02b020a4e90a6da1c5634b62cda5bad56f13bd524cb49e610bff3c55870edaeb3fa81e2dc23d155b041716ff75c72484d354a0918d2f22fc69a1a0431ff0658fca47ba6f001db1fde91d3ea05f0a1aa488ce35a2d8c41f9520839a7bf078375d84322acdec17f376708195642526e5202178d5a1bba0c2f238201dc8587df9db7ff9b21416a568fa5cf230fe9d922bcd448e96b2abb51de5fb84c9829e6b9471b8c351fa40c0392bc31c1fdb629c4d48138fc0010b4dd8177c18180d865c771786e294af94f94b3ac331237046ddd74c4f8aee101e1ce3248f5b85cd7575f4b21e21a04e56f21488812bd2fd03187af236b381d1ac23cda45b0c1b5c10317178d64d0f02ea9bb866da68160333453fd5d593cbd26595c17a089d6aab5ea4ccbfbd70a8e31f8b88f74e1e78ce7da1a67da6e45802b8612aa66883b11f7b45de3fe0c9f18e9c876f9ffd6cd352a6050d95fb6157312e3f232af0bfcd8528a61b67770aef26c32349c4e5627ee1c03d1f9fffa04d21400557bd658a8ca0b03b73670ad139a89b5d449188beece3a48b98a57dd12fe1186af747381130cf21ee29ac8b506e1c5431b5f829d0c0637f43a83d9a3871c0a72284ba332133e7e5d444a9d618c5ff457fe142291cf222f2f99933e7661a21b6969cca2667bdecc64e55d9a99a790e247d6c4ba6d6403e74c70dc94eadd4512052b966692756a8691012543acec92a6d41ef126e7f5c56790ccf0dbecbc0b27b9447d92a76daf8ed1d21d559565f98167850965c2a0377f596f5307697ae60aec6b8f1c47cba46f0da9692f52f116308b027793bad4ad2c3f1ee25c6f2ffb";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"f0f04fcce9192b6adad51ac756798e69ad9902537124af091fbc0de6075a682063c7606f00000000aee0ee9e00000000ff230fec00000000391e64c000000000c82a027700000000947973ce000000007f6f1c900000000088c821dd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005006517b6ccde5da4d890587ba62845b5af8a307c00e87d4b9d05099b16dc80";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"003f3009b31171950d66f9ec43c0c43ed73c2eaad1e9b3204095837e6f6af9ac23a8d7d7c7c3e5dc4bfa34e693bd643f472ba2e1dd5f040ba3d81a1a094d0b0f25960e9b09eb10716712808771bc34c5d6a7d1a131d67d5a5992117b4f9777812a382f53215765e829447fa489aeab130c14ad6fffbc043ca5be1385805ec5ed07b75d3a7d65c83f2edb6afb47586db1758360484fbcf5830dda911c848cfe261f2f8cda430da234f28002885643d11ded655a9c455018a7f86267b4a7766be62e985380150783d9bbf982871acc4a78a425643d8c84c99da34e5d79e1b1eda61829e57c4c957f7543e1b610e38ad22e7d68daee19944f119c0136f9d7aef3091c4a8607e92d2de999db196db8850fe906e3909d6175b01ab4696e1e839c64e01a8234ffd8b789f2994e93b7b54c921ea95ae5591f3efd48e02e98e282489eff04f9a6d6ada29197964bc93b36727fb02d53245aba001742ef1c7ea7bbbad4000173c4f3a1d3c49ec12ad146d2514ffcc538a81c8411f90a5cc5ede177b7779914d69453de75771836f25327f1be5441f60e54f0d14738c7bc6abafb1da42b94109f4041332fe5701c528c8cae114c80c0eacf66064f20236d161db4015c9f6e1d8fa27ebd3e24bd9e0a336e89ee340f0f5ce2cc86e9e91db196d7f2a117133117c8116e20bc7400fc36afa0fed567abe9a9f3ce793ba4cd94f2134027c72de91fa0f5394a2e98aafc5c0d10bb14a23ddfb89d1c16ccd65f5c316817e8f5f4b71b2ba4234593577c5c2ac1a0bad8a872c5c7b74f8457121fda4e53cf19f5f06804aa3f2d3c57666aa8fec1c9993422a160c9c9a23429121f1a65576c004ea5a21557ae337f2f872802f5fdae2d972b7a2937cda55fd3f6fdb186b2311ca6d9fb304cd2ef89ee2e1fe152f2029a898d857fa5f61885f777b8043440960840082e28dbcf96b24b282be99927f92d7fa91198dad322ce10afa4e0356026f53ae01515cf8d144c604795763f97b2a7684d661c53183ae2c6c40a59e5a242fa501c002217fffcd4f6f412ed1e6a63c33dd53509e1dc8cf5934e843fc9d1e45986f4e0";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"27e68756ce585201b839f16f08d58eab314871d3f7fad020b41061570c7bcf2a519f144900000000ebefb30f000000002778bb9a000000004c54448500000000e878739900000000d695679d00000000aac3a27200000000e8b2a43d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005006517b6ccde5da4d890587ba62845b5af8a307c00e87d4b9d05099b16dc80";

    /// @dev The four batch commitments the aggregated proof ingested, in batch
    ///      order. MultiProofRangeVectorTest pins the same vector.
    bytes32 internal constant COMMITMENT_1 = 0x63c7606faee0ee9eff230fec391e64c0c82a0277947973ce7f6f1c9088c821dd;
    bytes32 internal constant COMMITMENT_2 = 0x7d6a5ed6ffda210164c11dd6f6fccbd35c4ff70632e845a5bf256e3ec48940b9;
    bytes32 internal constant COMMITMENT_3 = 0xd5a7b4485d1aece18348655132e73c86b23fa0f251adb173f80123d05a914f15;
    bytes32 internal constant COMMITMENT_4 = 0xc5ed165443011bac65df4d0f4240de3429c033996e9fce630a631e117537cd61;

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev Byte length of the ZiSK public-values preimage.
    uint256 internal constant PUBLIC_VALUES_BYTES = 576;
    /// @dev Word index of `rootCVadcopFinal`, public-values bytes [544..576].
    uint256 internal constant ROOT_C_WORD = 17;
    /// @dev Word index of the first all-zero guest-public slot, bytes [96..544].
    uint256 internal constant FIRST_ZERO_WORD = 3;

    ZiskVerifier internal ziskVerifier;
    bool internal plonkVerifierAvailable;

    modifier requiresPlonkVerifier() {
        vm.skip(!plonkVerifierAvailable);
        _;
    }

    function setUp() public {
        bytes memory bytecode = vm.envOr("ZISK_PLONK_BYTECODE", bytes(""));
        if (bytecode.length == 0) {
            require(!vm.envOr("ZISK_REQUIRE_REAL_PROOFS", false), "ZISK_PLONK_BYTECODE is required");
            return;
        }
        address plonkVerifier;
        assembly {
            plonkVerifier := create(0, add(bytecode, 32), mload(bytecode))
        }
        require(plonkVerifier.code.length != 0, "Backend deployment failed");
        plonkVerifierAvailable = true;
        ziskVerifier = new ZiskVerifier(IZiskSnarkPlonkVerifier(plonkVerifier));
    }

    /// @dev Load a 768-byte SNARK as the 24 words the Plonk verifier takes.
    function _proof24(bytes memory _proof) internal pure returns (uint256[24] memory words) {
        for (uint256 i = 0; i < 24; i++) {
            uint256 word;
            assembly {
                word := mload(add(add(_proof, 32), mul(i, 32)))
            }
            words[i] = word;
        }
    }

    /// @dev The same 24 words as the dynamic array `ZiskVerifier.verify` takes.
    function _proofWords(bytes memory _proof) internal pure returns (uint256[] memory words) {
        uint256[24] memory fixedWords = _proof24(_proof);
        words = new uint256[](24);
        for (uint256 i = 0; i < 24; i++) {
            words[i] = fixedWords[i];
        }
    }

    /// @dev Word `_index` of a public-values fixture.
    function _word(bytes memory _publicValues, uint256 _index) internal pure returns (bytes32 word) {
        assembly {
            word := mload(add(_publicValues, add(32, mul(_index, 32))))
        }
    }

    /// @dev A fixture's own single public signal.
    function _signal(bytes memory _publicValues) internal pure returns (uint256) {
        return uint256(sha256(_publicValues)) % RFIELD;
    }

    /// @dev The range's per-batch public inputs as the ZKsync OS lane passes
    ///      them: the untruncated batch commitments. `PUBLIC_INPUT_SHIFT`
    ///      applies once, inside the fold.
    function _rangePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](4);
        pis[0] = uint256(COMMITMENT_1);
        pis[1] = uint256(COMMITMENT_2);
        pis[2] = uint256(COMMITMENT_3);
        pis[3] = uint256(COMMITMENT_4);
    }

    /// @dev The exposed wire-form pins are exactly the fixtures' public-values
    ///      bytes [0..32] and [544..576]; the pad bytes and the zero region the
    ///      reconstruction assumes are present in a real aggregated output; and
    ///      the VK hash commits to all three pins.
    function test_pinnedWireForms_and_layout() public requiresPlonkVerifier {
        assertEq(BATCH_PUBLIC_VALUES.length, PUBLIC_VALUES_BYTES, "batch fixture length");
        assertEq(AGGREGATED_PUBLIC_VALUES.length, PUBLIC_VALUES_BYTES, "aggregated fixture length");

        // The batch fixture is an inner state-transition proof, so its wire
        // [0..32] holds the inner pin; the aggregated proof attests to the
        // aggregator ELF, so its wire [0..32] holds the aggregator pin.
        assertEq(ziskVerifier.innerProgramVK(), _word(BATCH_PUBLIC_VALUES, 0), "innerProgramVK");
        assertEq(ziskVerifier.aggregatorProgramVK(), _word(AGGREGATED_PUBLIC_VALUES, 0), "aggregatorProgramVK");

        // One cargo-zisk setup produces both proofs, so both wires end with
        // the same vadcop-final root.
        assertEq(ziskVerifier.rootCVadcopFinal(), _word(BATCH_PUBLIC_VALUES, ROOT_C_WORD), "batch rootCVadcopFinal");
        assertEq(
            ziskVerifier.rootCVadcopFinal(),
            _word(AGGREGATED_PUBLIC_VALUES, ROOT_C_WORD),
            "aggregated rootCVadcopFinal"
        );

        // A guest public holds a 32-bit value, so the last four bytes of each
        // of the eight slots the digest occupies are pad.
        for (uint256 slot = 0; slot < 8; slot++) {
            for (uint256 offset = 4; offset < 8; offset++) {
                assertEq(AGGREGATED_PUBLIC_VALUES[32 + slot * 8 + offset], bytes1(0), "digest slot pad");
            }
        }

        // Reconstruction leaves bytes [96..544] zero; the aggregated fixture
        // confirms that region is zero in a real output.
        for (uint256 i = FIRST_ZERO_WORD; i < ROOT_C_WORD; i++) {
            assertEq(_word(AGGREGATED_PUBLIC_VALUES, i), bytes32(0), "zero region");
        }

        assertEq(
            keccak256(
                abi.encodePacked(
                    ziskVerifier.innerProgramVK(),
                    ziskVerifier.aggregatorProgramVK(),
                    ziskVerifier.rootCVadcopFinal()
                )
            ),
            ziskVerifier.verificationKeyHash(),
            "vk hash"
        );
    }

    /// @dev The production path over a real aggregated proof: ZiskVerifier
    ///      reconstructs the 576 public values from its pins and the range's
    ///      batch public inputs, then the generated Plonk verifier checks the
    ///      pairing. Nothing here is mocked.
    function test_realAggregatedProof_reconstructedAndVerified() public requiresPlonkVerifier {
        assertTrue(
            ziskVerifier.verify(_rangePublicInputs(), _proofWords(AGGREGATED_PROOF)),
            "aggregated fixture must match the pins and the reconstruction"
        );
    }

    /// @dev A range that differs in one batch reconstructs a different digest,
    ///      hence a different signal, and the real pairing rejects it. This is
    ///      the cross-proof binding enforced by real crypto.
    function test_realAggregatedProof_tamperedRange_rejected() public requiresPlonkVerifier {
        uint256[] memory pis = _rangePublicInputs();
        pis[2] ^= 1;
        assertFalse(ziskVerifier.verify(pis, _proofWords(AGGREGATED_PROOF)));
    }

    /// @dev The generated Plonk verifier accepts a real inner proof for its own
    ///      signal — anchoring the pairing, the sha256 field-reduction and the
    ///      preimage byte order on the per-batch side too.
    function test_realProof_fixtureSignal_accepts() public requiresPlonkVerifier {
        assertTrue(
            ziskVerifier.PLONK_VERIFIER().verifyProof(_proof24(BATCH_PROOF), [_signal(BATCH_PUBLIC_VALUES)]),
            "batch fixture must match the deployed Plonk verification key"
        );
    }

    /// @dev Corrupting a proof scalar (an opening evaluation, still a valid
    ///      field element) makes the pairing fail.
    function test_realProof_tamperedSnark_rejected() public requiresPlonkVerifier {
        uint256[24] memory words = _proof24(BATCH_PROOF);
        words[23] ^= 1;
        assertFalse(ziskVerifier.PLONK_VERIFIER().verifyProof(words, [_signal(BATCH_PUBLIC_VALUES)]));
    }

    /// @dev Changing the public values changes the signal, so the proof is no
    ///      longer valid for it — the sha256 binding is sound.
    function test_realProof_tamperedPublicValues_rejected() public requiresPlonkVerifier {
        bytes memory tampered = BATCH_PUBLIC_VALUES;
        tampered[32] ^= 0x01; // flip a bit of word 1 (the commitment)
        assertFalse(ziskVerifier.PLONK_VERIFIER().verifyProof(_proof24(BATCH_PROOF), [_signal(tampered)]));
    }
}
