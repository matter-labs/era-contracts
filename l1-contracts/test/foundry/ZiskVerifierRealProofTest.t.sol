// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ISnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/ISnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";

/// @notice Real-crypto anchor for the ZiSK verifier stack.
/// @dev The fixture is a cargo-zisk v0.18.0 `prove --plonk` output for a real
///      ZKsync OS batch. It holds a 768-byte BN254 PLONK SNARK plus the
///      320-byte public values `innerProgramVK(32) || guest publics(256) ||
///      rootCVadcopFinal(32)`. Its single public signal is
///      `sha256(publicValues) % r`. The proof comes from the inner
///      state-transition guest, so its wire bytes [0..32] hold the INNER
///      programVK. An aggregated proof holds the AGGREGATOR programVK there.
///
///      IMPORTANT: this is a single-batch STF stand-in whose public-values
///      word 1 is a RAW batch commitment, not the aggregator's binding digest.
///      The production path now RECONSTRUCTS word 1 as
///      `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`, which differs
///      from this raw commitment, so this real proof can NOT be driven through
///      `ZiskVerifier.verify` (that would build a different signal). No real
///      AGGREGATED fixture exists yet, so these tests instead pin the real
///      crypto the reconstruction reuses: the generated Plonk verifier, the
///      sha256 field-reduction, and the 320-byte preimage byte order (pins at
///      [0..32]/[288..320], zero region [64..288]). The reconstruction of the
///      digest -> signal against a real aggregation vector is asserted in
///      MultiProofRangeVectorTest.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte ZiSK BN254 PLONK SNARK proof.
    bytes internal constant PROOF =
        hex"0531b9b9611c9d3a0eb3f7c45d2ee88d96a7c7ab73c11106da88d1742122fbac157d99347c4ffe5c5c05dfcb58f8b6e7b972d9d2c719fc6013b4c96f7a9115991fae25c4a930931a8aa767494c2d602af6dcf47dc7ad4091b9dc00d2ed45d0842e7711d6acb1dd85e0100eb6bbc50cf99cc40523fbebe43969e924f571fa00ec1d5f9f5bf8876aee73973d1cba73557dce672e033fd42cdff39abe52b1babe08042a2bf4cea078ff74411172093f0c9877cd4a6afa0b340dafbaa3a3acfbd9cb0fe3fe3398298e187f840238f0b38a95258813bf5504290d10df09dfeddc05550795a4c454f9ffcfa271b2cbab9a3d3dad5c20429e6ceab7a9492c99e83dd27d19eb517c0fd3c9dcceee9c8defa5eac8a6ea6d19f2b209b9e99b5f6e84e388e907855c0aec0a81541585076c9a2db5cb931155a6e3042461406e7d6e6b94e2962ee6604f4f0fd3c9a80203573d152a73d88889bce92584048dd701a671ae721f1c268435bc229e1d4b67457a095d75fd83d27f917ca840bab23c1cf151cdbd3f2d32c305f97103d735fd7d7fed79f708f23f73311735eced6ac3e19d79227e1b172a8123c8a4deb15909118d55ea8953e2ff086041b1bb3b5c60a1fc5c12b6dd16d4080ded69a561b7702037ac98fb71c33d76dc79b3fad25807533b7282c7862e3e018c7aee5d4d1f8dd874802ffd6d66e14db055b75b9c80125175fde3ee3a15e8b809ba27f659fa4d02a68f2b2cf9d92b1a1b4ee502ce47d6a241deb27ef0239f346c5ccdcffc78ca310cd50487390668249a9ebae8ae1a12bc38e86988241a12309a39b62e1ea3bbbecc02dcbe2acc3ff8e7cf0a4421d317ca5c2c6dabb22e6a47bed5313ff23a9ebd328361116231edd9ad3f0ba1a03ffa9eaddec39ef515c3a94d03e6b859bd5908156f7908c1188a3ab4dfb58187a01993c2866b9ad60eb896b2600db85982160c833a59a67f77b478a3f92d9e26e126bd18617b7d5622e01ee3089a39310adfb34b3573b48d40388c0ddfc5c9df0dcf49babb20a32b043828fb4e8f8637a05ac96d74528f2e6d837ef79b88031d4d970a4f6a09235f";

    /// @dev Real 320-byte ZiSK public values (raw-commitment STF stand-in).
    bytes internal constant PUBLIC_VALUES =
        hex"481748830df5c3b7aa5522333ace2c4b533352637b92fd3c83ecc506c5104ead95693fd871251f2a04f558f94852d31d4f7b0cd38b0ee2c746bd2851dc701dca0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

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

    /// @dev Load the 24-word (768-byte) SNARK proof.
    function _proof24() internal pure returns (uint256[24] memory words) {
        bytes memory proofBytes = PROOF;
        for (uint256 i = 0; i < 24; i++) {
            uint256 w;
            assembly {
                w := mload(add(add(proofBytes, 32), mul(i, 32)))
            }
            words[i] = w;
        }
    }

    /// @dev The fixture's own single public signal.
    function _fixtureSignal() internal pure returns (uint256) {
        bytes memory pv = PUBLIC_VALUES;
        return uint256(sha256(pv)) % RFIELD;
    }

    /// @dev The exposed wire-form pins are exactly the fixture's public-values
    ///      bytes [0..32] and [288..320]; the zero region [64..288] the
    ///      reconstruction assumes is present in the fixture; and the VK hash
    ///      commits to all three pins.
    function test_pinnedWireForms_and_layout() public requiresPlonkVerifier {
        bytes memory publicValues = PUBLIC_VALUES;
        bytes32 wireProgramVk;
        bytes32 wireRootC;
        assembly {
            wireProgramVk := mload(add(publicValues, 32))
            wireRootC := mload(add(publicValues, add(32, 288)))
        }

        // The fixture is an inner state-transition proof, so its wire [0..32]
        // holds the inner pin.
        assertEq(ziskVerifier.innerProgramVK(), wireProgramVk, "innerProgramVK");
        assertEq(ziskVerifier.rootCVadcopFinal(), wireRootC, "rootCVadcopFinal");

        // Reconstruction leaves bytes [64..288] (words 2..8) zero; the fixture
        // confirms that region is zero in a real ZiSK output.
        for (uint256 i = 2; i < 9; i++) {
            bytes32 word;
            assembly {
                word := mload(add(publicValues, add(32, mul(i, 32))))
            }
            assertEq(word, bytes32(0), "zero region");
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

    /// @dev The generated Plonk verifier accepts the real proof for the
    ///      fixture's own signal — anchoring the real pairing, the sha256
    ///      field-reduction and the 320-byte preimage byte order the
    ///      reconstruction reuses.
    function test_realProof_fixtureSignal_accepts() public requiresPlonkVerifier {
        assertTrue(ziskVerifier.PLONK_VERIFIER().verifyProof(_proof24(), [_fixtureSignal()]));
    }

    /// @dev Corrupting a proof scalar (an opening evaluation, still a valid
    ///      field element) makes the pairing fail.
    function test_realProof_tamperedSnark_rejected() public requiresPlonkVerifier {
        uint256[24] memory words = _proof24();
        words[23] ^= 1;
        assertFalse(ziskVerifier.PLONK_VERIFIER().verifyProof(words, [_fixtureSignal()]));
    }

    /// @dev Changing the public values changes the signal, so the proof is no
    ///      longer valid for it — the sha256 binding is sound.
    function test_realProof_tamperedPublicValues_rejected() public requiresPlonkVerifier {
        bytes memory tampered = PUBLIC_VALUES;
        tampered[32] ^= 0x01; // flip a bit of word 1 (the commitment)
        uint256 wrongSignal = uint256(sha256(tampered)) % RFIELD;
        assertFalse(ziskVerifier.PLONK_VERIFIER().verifyProof(_proof24(), [wrongSignal]));
    }
}
