// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ISnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/ISnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";

/// @notice Real-crypto anchor for the ZiSK verifier stack.
/// @dev Both fixtures come from one cargo-zisk v0.18.0 session over four
///      sealed ZKsync OS batches (2026-08-21). Each holds a 768-byte BN254
///      PLONK SNARK plus the 320-byte public values `programVK(32) || guest
///      publics(256) || rootCVadcopFinal(32)`, whose single public signal is
///      `sha256(publicValues) % r`.
///
///      The BATCH fixture is the inner state-transition proof of batch 1, so
///      its wire bytes [0..32] hold the INNER programVK and [32..64] the raw
///      batch commitment. The AGGREGATED fixture proves the whole range, so
///      its wire bytes [0..32] hold the AGGREGATOR programVK and [32..64] the
///      binding digest `keccak256(innerProgramVK || rootCVadcopFinal ||
///      chainedPI)`.
///
///      `ZiskVerifier.verify` rebuilds exactly those 320 aggregated bytes from
///      its own pins and the batch public inputs, so the aggregated fixture
///      drives the production path end to end: the reconstruction AND the real
///      pairing. MultiProofRangeVectorTest pins the same vector against a
///      signal stand-in, which is what lets it name the exact expected signal.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte BN254 PLONK SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"2702ed8de997e7f7d39405f743f81245407d50f1a0627e2da0c4334bc3e3f10509b13f0c68e588941af1f5834b25479a5705815303c6b30da2178b11cfc2e9b027ced0651b9674cdcc4c86d4960c989a61c4d2784e6b21df4e722705fe0b3b3f186575b91b2d81f6254f1686a43089e496fbda1de4beccfa2e8a9306f1f6f2200d678c551a013c3740d855455a795b6f4370e6325c109a79074b89212dbc9fd91a20e2e4f19e1fe16e6f7e4470ae52368973f0a57c925f429566552da51c750017bc0aeca571945e85438ebf3abb0eb619d6b0a2743a1bb36f2f24505e2480a720108667c516f55476105e5f3be2595b9e73d82b2837431ac36807ad642fdf3e16d04077b093ea53dccb31605674d5cc61bdcfa6039b366a681d177e581e8afa042c92917135a25ef884f011ab14dbea12ab1b6afec1cebc1c5a137149f099201507e08e3ff4f0917723f9af176801a5f87d573778e7d9adf33e6568ae2b58ee27d255e5dd762c46c16862a93b83806d508946324e9b4d1c2b2442a1e2ede7810e9bb4b21a9be7316018d589565b7cfe135e9fc3d760aae7338625a7d5d0cae130418ee2fd1383b797d0bda5b4d5f0b82758ec80f34810e1f953dc8769e21a9f070a50e0531b282fc12a1e855c4cead24ef5a53f4ec4def5f1302aa4715f210d06ab95781282035752600213701ca43d910e475ecc95cfebe604e14593cb06a50739b783615fa2f6f67adc2cf8dc306d827a81e204e78e80006bd60918d72b8b1ddc0a9bb69d0e4d6ba45c75b23b52801ed105d90231eacb64914236b13226de16c955a25a533a8b0c283fbaca46c20119d7408de10423ee5aee2605a150f9f323b7716828be014292f8408578aa360a31232680842f7b178b1f2dbfe68e19130f525caa815a96dd7d6039c92b3f35fccf6627c8764117e0098052676d6424d8155021222e63a1d073f21e2419f809cdf1dc4f5410bb3e6ea30e5a3a548f62610a471175871a78bd8d627e9d96e4113971da45b7ea0a428e8d340028aeaf95f012bb2d23c95f5689430539e26c5b5fa8bfc8abed0ec7c89a7caa8dd929c93413";

    /// @dev The batch-1 proof's 320-byte public values. Word 1 is that batch's
    ///      raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"44e3d132399c8f3a03ce9672ba0ca00c6503db918731c7ab46d6faea445236ec5aa9a30847d37bb20955cfe6a65c916d4d0c504c8e5bb0965db8a90aba1e99380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"281492e04a2ed95fa431865bd57d8b3cedeff869b50f23987920dd935eaff09d0363d7e58ea159becb4092aacf0b59650a263fc68c4e8e7341d32457fcebb3e3008f71014b62f505dcac179fe12d7afc9202b56438fb469ff13d4943fab640f9142be792fea95435177e5e05831839469b69dbeb1cc9eec8e9d27d95480aff831d14c59404e006499efedf6f5133fe47763debcd0b7a6c8de4a8e7c2a39498e31ba68bc350eaee89d0a6393674f18b1571506cfe9d68ea00d78430a33a125f972b8c0f661caa7a8fd37447479fdc723d7ad1325d119abbea6a6960ed1ffb31cc005230909559a894a7addd132141f3d34cacfbbdae1b20e8af8d95441b3488ec1c6608456961ff514031857e3562133c7fc0d0c7128284ac9848bc2a8d9c18262c9d05d27f3b636f55f1c3f8ee0fce6b6bfb18e8281bda658edc47478907f0422727ca7ff5badae06f29292b44e419c871f6dc36a783afb0a5681a97986b83240337b396c5d0d4833698ad1acaf343ae0ea36e8af10eaa454a2743db5ade412510a31a6d7dc21112393d6a6559bfd0f7ee84a3928b3f3ba00dc996f36255c8d11bbb1e1bacd6474f237a2a321642fb887e1ebf324f7058b01c5f341b239f71bf2ac81c12921f84794107d4aef76d054c28c752511f12fb7b2a0a8e113bfa4a6d06855f08cb441014c7768951d00846e3221e66b3c94dc5659ddca563510935272c8e3ed2987fd052fa12961da47c8b45007e09988a3e0a7652c7f78d61f35633268a9ca41c9b37d1bf0d52a06f1827c1f7491406c1e29d9cf7e6c53361ace9b501f346f5764214b6a4d6e58d29706514d6e24c6ba4aa84245e704bd70c3f8b561f2ed546385fb4047b3c17caaef2e43b9f3d990a35c6bdcee1c9c2418ad599da1485807e59d244ded090875198c63824ddfdb41c650eacea9b3a27689eddcc77178665918511a5162013a01c7c33ecf08b3f1d1c5f237a2bf7e23a742873299828e5e5ba51750e0427ada8914e5746935236e73236177a0056b920d5aea53fa52313559d201c061a0610a8d9b5d7bffb177bec5ac7238199aec1694caa218026";

    /// @dev The aggregated proof's 320-byte public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"4c3d7317a62f651d813ba6afbbce59e45eaa7c009ab2a9b51d2f0fb3e79872548d3dc379548b65d0ed7df762dc646bf46fdbdf628cfe483479392ea8159e405b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev The four batch commitments the aggregated proof ingested, in batch
    ///      order. MultiProofRangeVectorTest pins the same vector.
    bytes32 internal constant COMMITMENT_1 = 0x5aa9a30847d37bb20955cfe6a65c916d4d0c504c8e5bb0965db8a90aba1e9938;
    bytes32 internal constant COMMITMENT_2 = 0x167bf6f9edbe48835b6b60e98af53552b0126765a804b86a3d7749daf05a5f4e;
    bytes32 internal constant COMMITMENT_3 = 0x8f03a8b3b8b78ef7ab5004817c9ebf211b09533b9a0ad86440396f4605ab794b;
    bytes32 internal constant COMMITMENT_4 = 0x3db0606d441cb57e9c621be9052e759db43e7c5c608c6e810ce673d9a4503c45;

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

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
        ziskVerifier = new ZiskVerifier(ISnarkPlonkVerifier(plonkVerifier));
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

    /// @dev Word `_index` of a 320-byte public-values fixture.
    function _word(bytes memory _publicValues, uint256 _index) internal pure returns (bytes32 word) {
        assembly {
            word := mload(add(_publicValues, add(32, mul(_index, 32))))
        }
    }

    /// @dev A fixture's own single public signal.
    function _signal(bytes memory _publicValues) internal pure returns (uint256) {
        return uint256(sha256(_publicValues)) % RFIELD;
    }

    /// @dev The range's per-batch public inputs as L1 consumes them: each
    ///      commitment read as a big-endian uint256, right-shifted 32 bits.
    function _rangePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](4);
        pis[0] = uint256(COMMITMENT_1) >> 32;
        pis[1] = uint256(COMMITMENT_2) >> 32;
        pis[2] = uint256(COMMITMENT_3) >> 32;
        pis[3] = uint256(COMMITMENT_4) >> 32;
    }

    /// @dev The exposed wire-form pins are exactly the fixtures' public-values
    ///      bytes [0..32] and [288..320]; the zero region [64..288] the
    ///      reconstruction assumes is present in a real aggregated output; and
    ///      the VK hash commits to all three pins.
    function test_pinnedWireForms_and_layout() public requiresPlonkVerifier {
        // The batch fixture is an inner state-transition proof, so its wire
        // [0..32] holds the inner pin; the aggregated proof attests to the
        // aggregator ELF, so its wire [0..32] holds the aggregator pin.
        assertEq(ziskVerifier.innerProgramVK(), _word(BATCH_PUBLIC_VALUES, 0), "innerProgramVK");
        assertEq(ziskVerifier.aggregatorProgramVK(), _word(AGGREGATED_PUBLIC_VALUES, 0), "aggregatorProgramVK");

        // One cargo-zisk setup produces both proofs, so both wires end with
        // the same vadcop-final root.
        assertEq(ziskVerifier.rootCVadcopFinal(), _word(BATCH_PUBLIC_VALUES, 9), "batch rootCVadcopFinal");
        assertEq(ziskVerifier.rootCVadcopFinal(), _word(AGGREGATED_PUBLIC_VALUES, 9), "aggregated rootCVadcopFinal");

        // Reconstruction leaves bytes [64..288] (words 2..8) zero; the
        // aggregated fixture confirms that region is zero in a real output.
        for (uint256 i = 2; i < 9; i++) {
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
    ///      reconstructs the 320 public values from its pins and the range's
    ///      batch public inputs, then the generated Plonk verifier checks the
    ///      pairing. Nothing here is mocked.
    function test_realAggregatedProof_reconstructedAndVerified() public requiresPlonkVerifier {
        assertTrue(ziskVerifier.verify(_rangePublicInputs(), _proofWords(AGGREGATED_PROOF)));
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
    ///      320-byte preimage byte order on the per-batch side too.
    function test_realProof_fixtureSignal_accepts() public requiresPlonkVerifier {
        assertTrue(ziskVerifier.PLONK_VERIFIER().verifyProof(_proof24(BATCH_PROOF), [_signal(BATCH_PUBLIC_VALUES)]));
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
