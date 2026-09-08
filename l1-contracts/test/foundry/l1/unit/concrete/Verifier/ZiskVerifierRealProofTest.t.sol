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
/// @dev Fixtures: ZiSK 1.2.0-alpha, guest 0.0.6-alpha.1, GPU run
///      https://github.com/matter-labs/zksync-os-zisk/actions/runs/34199276557.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte BN254 PLONK SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"11b7c092160e200d9174bebe64a41488f6b959cc2b6ab329cc575280e8b7ec2104c61f3eb092a8e2f12f8e842c72275cdfcab7766b79d61c0e9b20621fd06d8206375f94cb0797ccc8c9cb97edac5cca977cd56ad44d308610b52da7902395250f2a2dfcb84de848dc19c9f653c08264a02413b49ea631bb100028f73e03b621183e5167f1e687a73bde692d880f14b9965f88193a9f393bd75edeb82a2e6c171a02b7654c544d792417377f333c99a67a510404addfdddd29cbb36b8a6451171b64bb78128fc440b1ff69f6dd3d2e696c2a55eb86d952bcde85830db50e209618d29bc6c477bac2b3eb8fac5e0465c38215d9ef23bd489a54ce9c8b5eea910f17eb155d316a07239c3b8ee28d1a27bec381abb6c32c6fdfe5fc83dc2330d7bb236464f52ef74d7cac48c509beb8ca4e66c9c297cf8a39d141b555717869e6e82c60ee827ade6dd40c32c76e50126ca6bf37d767a6dfba4a8ec44e619a3effc21d3b8c46e9dbd27eec95c06b62f47109253e2baf46d36a7d15f7dd152f13106c03e10b0f7e2b2ca81a59f24f10d4803206f3af403c3d71f3f65af3e90d35375e2e42827622d622d32efa44468dfbbeececcec9bbf8e41193c1955ca5124b9b4918f818c338f81a8b198491f5bc8360bfdf3a665e569193538307088f7395ce0824461be965c6c5f47927c6be54846b5fd4addbc22c74d534e2778e9ba8868d8208733a795361cb8192df7266e8e9e4d1eba7ce1d44df637c0607e251a6bb68f9111ef5e125468bf37d4c49273188dca4cfeb952f0cd3a12682edce13cca7110f12b20429cf11f9189abe5769c5755831a5fc49489614bd3fd2af06bfec70d0621aafe58d45dd3cf2ad0f471878220fa1d7f1c3920a6b1c0579a1081ac8eb62eb1165b12f20c006d6bb689ec864352cb1bf852219715fba23c70a584c5c484f83001ccf88003abb76eac44b64c8255459c0e63b248735ef46df54de0d24ceefcd1de85c8d9477e2b4eb292623d338868ceee9919919fb922a403d128e86c2f90a0517c5c03bdc22e676945b025b7cf5d7d575707aa6ac98741e1e5d9ee185d16d";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"189d6b11c50ef1db9885fed376479ed97dde719a59574a7946d8d612e25da97a63c7606f00000000aee0ee9e00000000ff230fec00000000391e64c000000000c82a027700000000947973ce000000007f6f1c900000000088c821dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000564c2b1bcbd5932c81cfad1fa786a98372eb3d6495257c2d944544334f84382f";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"1dcaa6a00fa96beab435594a96f056be131ad004cee482572c43bd0642249ea202ff4c4af999e285237ce455a5dc165a67fdbbe6862b2fed7ca9a0bb333f4f862e7758220044098eea632a0a8d308107f20b54bf8a3a7cb986ce28da4b07c72f25db151486d4db93a156f41416d1c754fc1030cebe558faf29bdd6d9d621f14a01479de2ff2566e47dfbdb12defe35f0c9d54ea381267557736e9d6a005ebdaf14f46ea6a6d839ec4bf8648380fd31810dea69c59c99c8c3c631fa9fb4b829d2124a6607064f316393dfa4e343be3fa1dbee5e227970107d466252afd83770941b1ece44f8188b899179ad8eb2ae60a0bc33ff9cc1cf826bda01aa0c373361a90f462902b6e76058fd4bf61581e3416f1491362f7084110f36a9f5284b90d4660badc32a7f227aa193c8f9a975665a3f9075d0fdc19ea4f4050026ef1696f17b1abf4bab0828a783e8327970c2bf8fc91e6dceafce8fd0ff97dfab632aab0bcf005b235651a4ae52c4939fd354cd8ecf423f6f730a537d1e330d7ee6d920a997236b6ff96a070c430ad88382644205e5827c0573ab0d8f306f7e3b2b2ad55fa70e911137fa4661f70b13e21ac15e51cc96ad7b37ea9a8e4408b4c573eb2c465316c0b286acd597d0b21a2d2dcc54741bfba3ade3844e017e3364506e2525d5e3169e3588cf455c7d40a0b7d5738fa4bafdaa976c4c8ffb8f9efc684da80daca214c7151ee764b4924e81fa0079549fa692b80841929d7fb73eb2e2e937ebdb7f01d94745b8af4f1bd701bf8c203752df48a6817d34eb525830334b8c22788849182d6c0b51133f715fb5cb0963ac18cf6ea6b57180dc92e04c1b196404182cbe16174e01ee3a7aa19eda746aa72b3b682f6caa50a0c0a50abf7a199e6abfc28701b52dc081fc40d64154b92f3ebe67046bd7dbb79cf876210dbda8d064d7ebe80a3de01ee604b181f7e0a90a7d40028e40bacab77265508a3996b75bfae1a8982156271b42fd50e5c4f1a6d404aefc5d79cb6b0c41b0b6d151ecb465163e00fe26fa845126dcecb51f9750512f28e92938a39fa1a000289662423930d36bbbca";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"10f0e91f54ad66e4e95713a1b4b9fda44ea3b06e51ed3430ef775ba8bef4a7c877808e0600000000c21c5f160000000008738e030000000045b0074f000000000bc67ef90000000037abfc87000000003b2499ea00000000b7953ce40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000564c2b1bcbd5932c81cfad1fa786a98372eb3d6495257c2d944544334f84382f";

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

    /// @dev External trampoline so a missing artifact is catchable.
    function deployGeneratedPlonkVerifier() external returns (address) {
        return deployCode("ZiskSnarkPlonkVerifier.sol:ZiskSnarkPlonkVerifier");
    }

    /// @dev The snarkJS Plonk verifier is generated and compiled locally
    ///      (see verifiers/README.md); when its artifact is absent every test
    ///      in this suite skips.
    modifier requiresPlonkVerifier() {
        vm.skip(!plonkVerifierAvailable);
        _;
    }

    function setUp() public {
        address plonkVerifier;
        try this.deployGeneratedPlonkVerifier() returns (address deployed) {
            plonkVerifier = deployed;
            plonkVerifierAvailable = true;
        } catch {
            return;
        }
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
