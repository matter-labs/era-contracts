// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ISnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/ISnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";

/// @notice Real-crypto anchor for the ZiSK verifier stack.
/// @dev Both fixtures come from one cargo-zisk v0.18.0 session over four
///      sealed ZKsync OS batches (2026-08-04). Each holds a 768-byte BN254
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
        hex"144e895405d4fcf5d0c32ec85d7dca97cd53cd7d3f1132a4f6cee2811ee221901931cb415cfd04546e012f08e2a2d3d776805de1735214e4b29f215a140a7c3b043d65557ca90ec864300bff579c1c6cfd3aea970dffcb8651ba0dfb5b264c430c9b37d54b519b79dac8ac4a9376a28aab3e48e2f21a1636b5313241145adaf619cada81bc9383c35306e76d860ef0867ebf6320287427c641c2b578009a60991a89dac0641c5c0ce6ac84905141645a91ec91008a5b1f6640f71a50fb9beb5926bd0e20375b6ce895b388f1478b4ed18fd673f71f71cd68262be602f12f4a700a9bd0f940961f658392785bd14b2bfb17f8c776ee9cd494b2442bb5cfdd630e1ff64131c00d77547c86a88538750d13980a7bb319229978f818663f8fe9105919ca8d0715aa40200992ae257768f56cb2bc48d5599573043dd1b3faae1720a72dbf0d81109dbc54e95328f82f47431883e0d04ce104480c39923f0a088f738523b13f3ce9bd7f5c718a0fc8f63d1a8fb20085f9d9792e04131c48d18c2456981a2c0a897bf44f03d509e83eefd339f21f323c075c70f952d072faa4622d3db428436d480e9b6203bf823665d4ee4420641b939d8dff5cea178c2ab72b1470e4156995c7aaaa610de5e8e6b184fff313ebbaabdd2c04663204af5ac1fb0885b629a2f1d9cba94d18bca50c65daefcfed0c292460aee4bfd7e8a91791a5a40fcf06a40a48dd1d2d54ace09918bc1778de3efa383182976d73c019039af8a232221924399d6cc500b7c23c8405a6d6ec9990648f45364d0e3456d538a2a6098d002975b075f082c87e7d012274c91623524c7322d10d722072930c800d91c06ff6041e491a0222cc4e580d4116ade499128eb886c39ce3dd0439b7929bdbcc516a0a2e134040a70518a573d789dced8793a173e54b0154475da3274838605584d30f21bc62912be37cb35b1ab7a4b2613e7fb08f6588785df9f8e258db55005a7325c92251dccf1b64dcd2a983015793e70007646aa2a7e3665f7819882c6fda911bc2a67b29cbd0775011aef436fb29d7db288737e05fb1511a1df9ade4dbd5b4";

    /// @dev The batch-1 proof's 320-byte public values. Word 1 is that batch's
    ///      raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"1d16f620e2bc7e58044df7ee8d4284422a0dd37cf151cf79ecf324c131e504686c41981c6fd0bd9a9262fe3dcc9fe4f0d8e142651f80316a8846d6922b5214ea0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev Real 768-byte BN254 PLONK SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"164b056363692b7d43a29554f955dd890b774126cf6408a765858cc0fccc2f501f5792b52cdb957733e714f3e82dfdbe3b6bc9a666d98ba4875f53c59eaf68251df1ae04d2375f173670af164f7ce8569557d8434b0350c0a8a8d8c01a5250ad2e7e2354863e0d00455989dc966cc810a542d88ebc055392ac94fe7a94f4e8dc2ed63a20787a2c8c25cdd10e974f5bd0b87401950986f02c012c8c12210d67562ad12b00a4b18962f5db67eb3c2adc0e93c5e8259d7255b1f8461c3d7487c9532bdc68fd185837e672eaae20db5495ca6f27eb1875ecedd0d6776244f3333d1703456215b07e612e96fc82c4278a0008d7648541085b999e3c3298de61f9432f0cc2e5d0f2f3a3949859539de87b7c142621a619ab2087ed6aa2f678d4bbd6fb03214e458cecf2f14c68dd1ef07af5999ff7235355b03c9899baf50a4ebadd0c2063d67263c17f9b0b3b9f55738f024e4a2c8b711fe8f229c36cfb00bfd6cbbd1db928b3b6b33b41e1b97e6cd3c0aafd5b15821f9d6d82c2e1308a2721aedb742f26c1b2d8e43a1fa22d4c56c0f623ad12f61a6a8fae698e0ae672db5276dbcb275dcba1106ffdcea1298e1a56ef149781aab67b9ad80b7f9488460b647e91271085dea946b5910fe1cc590b47f0e933d9cefa64126b70c0727296b24d980d800025d1e6c05cc056d9c6001433a3d85b2cccbb272569d353146e11062c7e0d4302c3091f13447a8b78842c0757eb99effbbcdbe5ed0de07992eb0c7a058747ff20ee5616a1b4690b8c8cffc74bb9b81aeb88dc55a89eed12a6cf79cf482b97220daa1cecbd9fe6b18a863637b374613af1811383bfdf3ca43507ea4aee3ee02426ae1f073fdd0f3d3c13f76bdd740f1d387b4a6c63f480f084fe8bcb2ea4fb1b048af1f2fc52d2e205875dd7dbac53057a8fa2758990bcbfded778bec8fe32ad1716bba15b3e4983dc1eb4f9c86bfcdf9434c32b3994f15881ee94536114adf62efae301b1f49432daaffa8d49e586774b401f366b93a882ec426256075e6b5a0af3be0d4e9a85f66db602eeb45b39fafec487dcc10a31fe3442831abf264a2e";

    /// @dev The aggregated proof's 320-byte public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"4c3d7317a62f651d813ba6afbbce59e45eaa7c009ab2a9b51d2f0fb3e79872547eabba6c7a68150706e10101195be54eaf3b39f699bc8da5f34c8033eedec13e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev The four batch commitments the aggregated proof ingested, in batch
    ///      order. MultiProofRangeVectorTest pins the same vector.
    bytes32 internal constant COMMITMENT_1 = 0x6c41981c6fd0bd9a9262fe3dcc9fe4f0d8e142651f80316a8846d6922b5214ea;
    bytes32 internal constant COMMITMENT_2 = 0x1f56fcbd24636dc0a635bc51808d7db9eabf3914f66611c93cf37ea440a5fe27;
    bytes32 internal constant COMMITMENT_3 = 0x9d909d7416f29633c361bfc00073a9004423f0e1cc46105cdd24550543c0e41c;
    bytes32 internal constant COMMITMENT_4 = 0x6ca5ada4916397cfb1b07a2f115f21fedf7e4a14a827995b3c5b392966532ad6;

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
