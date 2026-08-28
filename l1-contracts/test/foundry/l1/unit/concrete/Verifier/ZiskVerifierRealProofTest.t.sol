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
/// @dev STALE: the fixtures below come from one cargo-zisk v0.18.0 session over
///      four sealed ZKsync OS batches (2026-08-21), so they carry the 320-byte
///      v0.18.0 public values and a SNARK for the v0.18.0 wrap circuit. The
///      whole suite is red until the `fixture-session` workflow produces a
///      ZiSK v1.2.0-alpha session. A proof cannot be recomputed by hand.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte BN254 PLONK SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"23b0566bab58cc5252e65f98ab5cf30b3c3fb2afd71b45e2d64228fed7f4b77a2e5432bf507d3baabd49a3eaf0d0c4687ad4f043d56a866b2cd127f5a10cd48803b69f0a9a1a78e343dc669e7b8900e416c9d9fc585d02f2c7fba02dd35ea30222a22cec979d09104dc83bbb2a376e1dd885c1066cf4526aec23edf43c11b1e1133fa88f71fba7719d989237d0746bad7c5734953b30c9ed446a3b74caf640bd1c88216727194ceae2973cb8bbb25500a31b9630cfc9437f59516a8960e4285c20bb6dae7716b3f06d5f251684bce645ac29f7f25ccbf8c5295b7e53a97fa9ca25d95b64ae7459f436d12e813e6801bf632420472f6f7b79b7677ce78dc6acc721b408d830b757dbeeb7665cf71fd6daa99891c753e10e42084f321600a9eb9c1fd91005f8deee95950c09cc33ea7c8168aa0ffae6030554c82234fa08ade38023a264f547fc538f71f2277417d9e61d7dc78e477e284f0d736977789c122ed818c5959fd850df1833d5ddce7fde6494fa20fb594a8d320c66842bef58f0b6e72a2af93a85ea80c97b02b1c6cd386acd001c6ca6b594ebf39305e2fc3e98a7de0a3958010ea03c4e5ef5af9f79037bbfaf73625978bfae34c018d5bfcc861d3c176c7013f95357bd9bc3dec9f55cb0a1b4075643bfa3a02ebd851eebb29a4a8008fbc3df9e10ce910eddf0fd6f11cc76366710873ef5d2549252cd660434e0f1245d5b38a984b55dda02487292d9dbef87236aba92c0127daa1af6e9e5783f3a16ff21354570100694734e50fc03ef8c82510367db3e3dc4403e69ea56cfb18b265a1c0e1658851ba6162fdc9b55a220422da5b3b3f8b356d85d4454ab311b3d11feae791c471b421790702a56c361f7421deeaf2fcd7f8681f7efaf220e26b913af155e9a822bece1caf1bcb4fab419bbdbe83f3f9f94f3e9dedb21687e5b5903f12e5c28d2703b4add8b4679f0a335d84ccc67236e736318148fee826e90502df4914dedba044118277d26be0fae371f12b93a5caef98cb228aa9cca090c56158d38b6fc2e6e8d953c3d5f2f0631f15b72c2b7ca587fdbbb2c22d312c30ed4";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"8168c5d383a50a9c7a40561b82bf679cc6dfdab0308417b4fea653362d78d08063c7606faee0ee9eff230fec391e64c0c82a0277947973ce7f6f1c9088c821dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"0999e0be17626d02f67f9d67e9b23362bd82a4d7f74ac422f4d4c8b7d67ed5c8277e62b31534d47c30071cabfa721a7a854744cd6189290e3fdacd4ea306b1551e8f8a74f6c5aff259b6d4dff78c306f5ddc58fe8b97d7f94dd0108362bfc3550d6434de694c6f3a24cb87ef58131ef942009f1da0df63a462078c5e2b0e890f1e2fc2cac2fae5c017d2af1b18b1e8cbba0459d5ee962e3a279187e8ffa9a800070b7b9ac6954cf40f48d010aa2d10ee842ab46e23cb35adfdd71d882a5ecfdc07d36a96bcdddd1735a283f53a989a578524eac4bd260714aea5dd392e8eb0c7190e50b0045b523f7fdec15186409a53e9c1e75b3bb3aa1947e3173b58b26df52029d756ad78e0549d8ed7f8bdc8fdcd038c138c95a4c15adc96cf4ce1b1c37d146e9b5ab7ab2feacf82cf4fe4d75f37165a606b8adbeb070e490dff326a766c08c5ac551b80972bd320af58a1bd3f8f720ad0f30784f9bb8c835df4a98ad40e2a47861884c163c42d454696141c28268713bdea968eff668b5d13dfe51b74062eb56dbf7784a263d9adc2c16e0adddbd30162b0d6858d6234f9d51118f149d02d21997a43e6a52eda951cecbda8d76372fa14e18ee97329e992e584f4feb9ae16c374f0699d7c20726054ada7969f079c0221bf7d1105e09e0a1098d69f9c701717da727af190e1ee8b87425a0825fd154872ef9010559c45830cc64131c75f106ccebe6dcd4baa03364d5e4d11573058a4765a41f05172919f2068c751e4102b03a137a9e5937795a0dbb78df4f932bc56642f5d6fc0f1ffdf635a5f2637c6165b8b103e655db70f718c5b72a8ac0bcc4d5b09ed70bb59f15acf98287698dd099f6df6afb18356aabdd639734f80e773d46d5685a9d1875955334c6bbda45223f271fd9e63bf7bbfdb390341c7bf20a5123bf379338ba0a8c63dbdbcaf9e4316cb6a5bfc4bf6a418d02cca2d13ad8f31fcecc4fc715b803d366847289c90831505c708f3559fdd310a0f1b34df12d71a1cd30cb0d9fab275ff547260e914550acd848064e5675e101c7732543c40c4c15cf88aca79c5dc3ad831a5f0aa899f";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"f68b9862e424e377af7b4220a419ce45bc52ce70b0a37aea486a15a5ca38b738f29341c341f2622ba86a21bbb36dde9742e1983e531c278fd1cee04c6f823e2c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

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
