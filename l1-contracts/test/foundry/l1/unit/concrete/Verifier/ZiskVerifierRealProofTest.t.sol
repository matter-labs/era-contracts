// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
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
/// @dev Fixtures: ZiSK 1.3.1-alpha, guest ELFs reproduced from the pins in GPU run
///      https://github.com/matter-labs/zksync-os-zisk/actions/runs/37659618382.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte BN254 PLONK SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"1b06b727cffa4d2a5dc9263609d92805b89abd004d7331856c6c85192d12933414711b7ddda63c6d5f2055649e923fdefc25e6826453626ef02f77b73078b33b0580bf9121447cabc003f5436e0603a4be54a12f97580ae4e36356fc9bf8f70d06becb4949a2287cdde91cad3b6102a4d83a61914918e6e61930cc51ccf83fe2077aa59a1d81341c80ef4427e5942e5fd93159d8cc254070e37b8379fbf2c57d154e1316fe74c3e91661b930f45e5851c0ff8ba60d4724294641591578e627da1f183c87de943a30da24f911bb6c01238c65871ecbc85772c69ad930f117c02816bd79e631cacc062c3d316162f19b974ea76b5a7ba396de7d108a5cde24a10e29a4c1fa6a3e8f6d903e706e61d154d0be4e2f6fab822f047cf47551efc5923c040636f262c969b492d2a6645b357aee7d11bbcf260b44d9d78044d360e6b97f12654a658eee8773d8c632ee6dd5895798da5662aa5f81ee0c5880019147418c2f4dc132e2cf56a29cc7106879461e76ac2e4ae858b3ff89cb60f64e24a0af0f0f01f0dab02cf42f0c85a7507c41663dd3384f0d5518cf074b9d71ed8f452ba0068abf15e03d55591c420004ab701dab55e2c7ef3345f3081c60d5ebecd13e5024d8f3401366abc4d92545a0d9090e9600329c49a65f68047d62fde7da452a232522e87141b809d1f6ed982d241c57561aa83a4828337d0d1a01bc16b3efa80e0f7329d7478447d9d3ca1d75d838329162fa6d8c1da490b5d3b5f4c904cac7a31c1976efa6c7bf7b0f997c16521cca977875a66c4a67586f5fc89aa50360564a13aab7f16260fcc05af7ff1a4cfabadc6e138f4e27c77d250cf41ecb194dbec9145d3d4dd107a33343a65d78fe1a13d531285601df77b24d44c628c0e4ab301c265969e06de36afaf37dfc7f51a93f9600735e4da1c17110e5c5297a77e7742b1ddd82e0446259da529cef718b12c052c739369ca93556e2bc2ec9769f82a4570e4de9f142b1122daef0f59ee867ef389a21b16950d0b4172a688bc0c7dfa33f1224b1a86c2cfb212f2faae8964b9dde35912534f3839f9a631a3d1adec54280";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"93172dbe40432534d5ad84e95b3d2324c6e9a28c1fbd6b770776e4c8d31ec4b963c7606f00000000aee0ee9e00000000ff230fec00000000391e64c000000000c82a027700000000947973ce000000007f6f1c900000000088c821dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c3f12b9f8707c6a1e96df2bf6702c2ebdfbafedabeac654644a380befe091ac4";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"25bc40c606cc31b14ffaedd0d4316ee124c35dbc7c8424400161cfc3186ee2260f11fb41f0d86e650bef34f9349f3b5e9fe90eec9d2b39f2269046dd30cfa070083edbbd675287b5fb542f1cf0901dcc6820630eefcc7e1ae96c8b2872236ee61038560e0ba2e1caadb61b4e70be1410a445b1260f53ed0887484d30c709b9901d1337f126834630901a73983871daa421aa82ed73678fdf5b7f408d92d14fe6301859aed10c0d69c8d1676d895279dab5a6f669b2c2a3c17890fc7496dbe57a08c33611b17e3d58a270f06998148fe35bd0eebd2bd6419002d89691e7eef7a40fd69dbfd53b3e476a106f11a7a1c8ec1c629c6887e817c3921671dd2cb27dac051f46e1df22b5594324d47fb02c83d593f3ed72ecf05c11f6ced3ab8d1e949426f1024c8ade1e5723ad9419b1e6b2fca49901fa077a70c493804e851dbefa25009f40f23df5872e5dbe6c70765873cf7fdcfa5ee50591a1dd40abf620d914df1b8d77b4147123b46190d7f06b87f4ffb565ddd42ea22a0ce2d6b86085274a951369d87c9eeef4b74553c8b40967aa50e1adcf07635cf2a4fd16caad612d07282584bd5e731af8c9d95cf8d73916b308072847c84b6e09dd144cccc4fabe424b2549fcf2f7f1f250adcc5e6c2a54562d4c90cb41bfad2421148db40c088fbcd61e93d6dc03f41ffe98148eef0a28d395086ec1a71245afde21a0369946a8039e0f4a69bb196015f67211bea1ca1df67ee6c69014557f065baa8d7260a0d0794a238afda062778640c16366a674a7fbd58ff6386ea9bf859d61e9282a667208710fd867450707087baed5de90fad829d9ef38472bf3f7c866c28aadbab9f8ba330c5a40fb64ea9e99187afb7a960d2a28347d21414ba25bc0f2ce68b06926ccde2fbdd4d5b2e2a6bf4c9e54fc09104cd7e6d7c5928abe9c287fbdb67e7c30b978166d5e4449d8c0502b5885a46b0a5200d7fef61af0d254f6eb2f8d040a376a411377ee6b569d88e357a6416901aa1d3e4544c5c08eddcf4fa688e4d823ec1aa32461f2d0a79ad6a4520eab8dcfc29a18bcd1c11808731b6b16a8cc5294dd6f59";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"558aff7c3342a2636ea8aa9f91d151d0300b7aeccd43d682ac854a79548cb1a73d7f030c00000000acc8d29100000000c78c755000000000d5f0c7cb00000000c5fa5409000000005165dda5000000000f899d8e00000000b3809bcd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c3f12b9f8707c6a1e96df2bf6702c2ebdfbafedabeac654644a380befe091ac4";

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
