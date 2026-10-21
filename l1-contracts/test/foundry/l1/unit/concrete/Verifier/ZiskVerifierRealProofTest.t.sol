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
/// @dev Fixtures: zksync-os-zisk release 0.0.9 (ZiSK 1.3.2-alpha), guest ELFs
///      reproduced from the pins in GPU run
///      https://github.com/matter-labs/zksync-os-zisk/actions/runs/39274149227.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte BN254 PLONK SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"0df47546a29aa743c077a7a3ec40aae30a49b3e5c1b4f0c5e0ec90fcac72d9aa16fdc2b8d21d11fb8cd8a5984fbcd6aaf5935860ed8aeb0564793a59e7caef341934f863a3e0e371f39bb044326fe06d5d3edff793322eefc18c43f4ce9915621088b4971b31dd3254ae4129e05715b37569e87f1a86dd94c52c244f0c3fce880228aa570c4c4d4c3298363608c1f1819c87cca572c04e1966e627fe7322cd061a7b58ccdadc39781bd0c83c0e28afbe9c31dace64bc670111d853422b065fd91bdf74c28104b7048dc78ca784daebc5ee5f10f1741839b91a21a7f4a49218742fcca7f371152c4ad10a0039ee426370736a94d125330fe55ce11c154b4597a303996c74860714246b5177f9ee19f7b5b73b90170a363756467c03c6a62bd93b01e343356dd1d6de967cc2bd2a870bcc74b0d4c274170de06220114e9ccad8cc0424f9a908cae3b131cd433c69e3d4e4a705f2a013225e30e5efc8d3166b08f22c94d2456cc021eafe7feda467a087caa28d1b96ee1e72031972a2da47a509aa29b7e916a352803c615e9129138dc9f5e2e8170d74f09e53a9db7ada26ccad2a10f9c341d88c4cbbc9f5a3099b6bd70dce1d3445f4c760bdf8bd9f1553f0b19a0b1b1e0dc1ba463627fbf5552380d7624e5be9c6ee1440fbd37b84842956ea3e12df68e7eb21c99a662d107afebace50cb6bfec5fa52311540b2b137dd24d7742c0c004d366ec6a88dfcae172790bd0fbe7bc6e9a9dc76ab6d36ccc78a0e424b061250618783be2e1f88e88134b28fdf575447f19434b58890a71d8d4493ab042bb292c9f6a605fe8798c4d93d25cdae1bd40b5daaaea516fe1a087fa64b71862391412b4c913b8e9e1c8f40b21331df36ce54af6caa03bde837e9c4224769a42a32c24daf87dbb9372ee3b7fd7b0a697edc95da484aeef1b61698e057d95042100b0b45563403a53c4b2b51a63d0ffba6560bb49b133aee489571cc48fa4ae807d21ba862706a322910e4ba6a6e3d5f7d6b512ccb25807f2eaf6b335e2cb602231949c5ea1961d43f78896f25e19b3fcd7312008d02c3b08ab598f7cb38ed2e";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"09ebc4f2e17b20d69b6f2850ddfe187ba5b0514abffbcf789823cc6e4e44ef0263c7606f00000000aee0ee9e00000000ff230fec00000000391e64c000000000c82a027700000000947973ce000000007f6f1c900000000088c821dd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b2490fba336fb00f0c8719a961de309a8db6f43a9bfb7575ca5f014d609b265";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"1667bc9d08d1fd261e2f920c21fbad27589130a6a28b4e225d2f56d40189f9b12c638e597db0fd270b91524ef7cea9eca577c1ebb9feeea761596684265dcca818ee9fe5411aeb3c639861920a928453e55cb910b1405dbdc34e93c6d08d33771bee8e9465dc141df8e7c052c3b5a25f16e7fcd9d177f2ecb245db0abe7927910e65a83b35275ce106505a5146150042f7852038455308e0555db35690e934882daaf32c2dcbbb65ebe5c5e3190ea77a79cb9cc40dbbbe26c4c3812a48fc0005093f17d3c9a05df14094a7252ef908b95c5915c360431a474072f97f50d1f50113b4ac8a0735c5a3c872219720f2fc461dc27413ff93f21d183c223bf906ed082f16880e3270fb735cc61da5dde268cf0566fb2b70a2bcc70c1e9c419cda6ea20508b1098b3212fdf7c67f71cbe5dd84fbf4f77756fda4e7422ae60174c1124b0082f691e23eac3a41cc5573b8112448dc12f3f2c8d874a38de2a3ea5cbc4315030b1a0ed8ce4dce59ae9063edc8cdd985ecb12786618cc2fa8bd619bbfbdc970c5f1b9888ae99dec784c06c03ef514c6a8b2c2b92ff6a932477b5cfde65e371042856b4813bc4cb7a9c0699d9f0cf634860d542ab79d600b274a888f671e5b22e7dc9820c282618d19e30f9d70ec6101be1f1ac9992a920c0632cf7c1e723b119fa53195190d18c662b104a639f7827ef83250b78779a494b9afecfc6748112262a27256c3adfcc76ec9458eebaa2280712e68a6121c5b028a875d797fda508187fc21cc8af1ce1580a3916ed647017dd4a786d075c97e6c2b5f7ad8b413aa22731633b895f575c4d9ff76fb585d320c5f6397ebb9b01db3ef8e4e47db277e41be3b5e3a94de1884b45201cc2d11354a08514e02225d16824b529f268cff92a073bfdd7631c7edfc4caefbf0e2bf9c17f69a49bb862eca6b873d38d7e9a69b92d23452e1d425219c2697fd4479e566ddff2e312f798dec37356dba5f10b4e242952b457911609e2cb297422ecc557577a2cc20a8b832d437ac141726079cfe01d4343f08fc06f8b1315499ba00cb85e97bfc2880e4d6c5370b2ad6f04c038ad";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"9e2ea93a5e08c2ddb5b93323a593ada955dc74d00fac433d45c97da5b90e5e08ec1bf9cd0000000008fde7ce00000000771e6ceb0000000096064b0f00000000a73b3a47000000005e7f6da800000000675989c300000000c40b13a200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b2490fba336fb00f0c8719a961de309a8db6f43a9bfb7575ca5f014d609b265";

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
