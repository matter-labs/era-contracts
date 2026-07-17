// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ISnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/ISnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";

/// @dev Mock Airbender verifier that always accepts (the Airbender side is
///      exercised with its own real-proof fixtures elsewhere).
contract MockAirbenderVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @notice End-to-end verification of a real ZiSK proof on the generated
///         on-chain verifier stack.
/// @dev The fixture is a cargo-zisk v0.18.0 `prove --plonk` output for a real
///      ZKsync OS batch: a 768-byte BN254 PLONK SNARK plus the 320-byte
///      public values `programVK(32) || guest publics(256) || rootCVadcopFinal(32)`.
///      The circuit's single public signal is `sha256(publicValues) % r`.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 768-byte ZiSK BN254 PLONK SNARK proof.
    bytes internal constant PROOF =
        hex"0531b9b9611c9d3a0eb3f7c45d2ee88d96a7c7ab73c11106da88d1742122fbac157d99347c4ffe5c5c05dfcb58f8b6e7b972d9d2c719fc6013b4c96f7a9115991fae25c4a930931a8aa767494c2d602af6dcf47dc7ad4091b9dc00d2ed45d0842e7711d6acb1dd85e0100eb6bbc50cf99cc40523fbebe43969e924f571fa00ec1d5f9f5bf8876aee73973d1cba73557dce672e033fd42cdff39abe52b1babe08042a2bf4cea078ff74411172093f0c9877cd4a6afa0b340dafbaa3a3acfbd9cb0fe3fe3398298e187f840238f0b38a95258813bf5504290d10df09dfeddc05550795a4c454f9ffcfa271b2cbab9a3d3dad5c20429e6ceab7a9492c99e83dd27d19eb517c0fd3c9dcceee9c8defa5eac8a6ea6d19f2b209b9e99b5f6e84e388e907855c0aec0a81541585076c9a2db5cb931155a6e3042461406e7d6e6b94e2962ee6604f4f0fd3c9a80203573d152a73d88889bce92584048dd701a671ae721f1c268435bc229e1d4b67457a095d75fd83d27f917ca840bab23c1cf151cdbd3f2d32c305f97103d735fd7d7fed79f708f23f73311735eced6ac3e19d79227e1b172a8123c8a4deb15909118d55ea8953e2ff086041b1bb3b5c60a1fc5c12b6dd16d4080ded69a561b7702037ac98fb71c33d76dc79b3fad25807533b7282c7862e3e018c7aee5d4d1f8dd874802ffd6d66e14db055b75b9c80125175fde3ee3a15e8b809ba27f659fa4d02a68f2b2cf9d92b1a1b4ee502ce47d6a241deb27ef0239f346c5ccdcffc78ca310cd50487390668249a9ebae8ae1a12bc38e86988241a12309a39b62e1ea3bbbecc02dcbe2acc3ff8e7cf0a4421d317ca5c2c6dabb22e6a47bed5313ff23a9ebd328361116231edd9ad3f0ba1a03ffa9eaddec39ef515c3a94d03e6b859bd5908156f7908c1188a3ab4dfb58187a01993c2866b9ad60eb896b2600db85982160c833a59a67f77b478a3f92d9e26e126bd18617b7d5622e01ee3089a39310adfb34b3573b48d40388c0ddfc5c9df0dcf49babb20a32b043828fb4e8f8637a05ac96d74528f2e6d837ef79b88031d4d970a4f6a09235f";

    /// @dev Real 320-byte ZiSK public values.
    bytes internal constant PUBLIC_VALUES =
        hex"481748830df5c3b7aa5522333ace2c4b533352637b92fd3c83ecc506c5104ead95693fd871251f2a04f558f94852d31d4f7b0cd38b0ee2c746bd2851dc701dca0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d";

    /// @dev Batch commitment carried in public-values word 1 (bytes [32..64]).
    bytes32 internal constant BATCH_COMMITMENT =
        0x95693fd871251f2a04f558f94852d31d4f7b0cd38b0ee2c746bd2851dc701dca;

    ZiskVerifier internal ziskVerifier;
    MultiProofVerifier internal multiProofVerifier;
    bool internal plonkVerifierAvailable;

    /// @dev External trampoline so a missing artifact is catchable.
    function deployGeneratedPlonkVerifier() external returns (address) {
        return deployCode("ZiskSnarkPlonkVerifier.sol:ZiskSnarkPlonkVerifier");
    }

    /// @dev The snarkJS Plonk verifier is generated and compiled locally
    ///      (see verifiers/README.md); when its artifact is absent every
    ///      test in this suite skips.
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
        multiProofVerifier = new MultiProofVerifier(
            IVerifier(address(new MockAirbenderVerifier())),
            IVerifier(address(ziskVerifier)),
            address(this)
        );
        // Every range, single batch or many, now verifies through the
        // aggregation verifier. A real length-1 AGGREGATED vector needs the
        // re-derived aggregator VK (a deferred step), so the multi-proof path
        // here uses a pass mock for the SNARK check. The real STF SNARK crypto
        // stays validated standalone by test_realProof_ziskVerifier_accepts.
        multiProofVerifier.setZiskRangeVerifier(IVerifier(address(new MockAirbenderVerifier())));
    }

    /// @dev Build the 34-word ZiSK section (24 proof words + 10 public-values
    ///      words) exactly as MultiProofVerifier hands it to ZiskVerifier.
    function _ziskSection() internal pure returns (uint256[] memory words) {
        words = new uint256[](34);
        bytes memory proofBytes = PROOF;
        bytes memory publicValues = PUBLIC_VALUES;
        for (uint256 i = 0; i < 24; i++) {
            uint256 w;
            assembly {
                w := mload(add(add(proofBytes, 32), mul(i, 32)))
            }
            words[i] = w;
        }
        for (uint256 i = 0; i < 10; i++) {
            uint256 w;
            assembly {
                w := mload(add(add(publicValues, 32), mul(i, 32)))
            }
            words[24 + i] = w;
        }
    }

    /// @dev The exposed wire-form pins are exactly the fixture's public-values
    ///      bytes [0..32] and [288..320], and the VK hash commits to them.
    function test_pinnedWireForms_exposed() public requiresPlonkVerifier {
        bytes memory publicValues = PUBLIC_VALUES;
        bytes32 wireProgramVk;
        bytes32 wireRootC;
        assembly {
            wireProgramVk := mload(add(publicValues, 32))
            wireRootC := mload(add(publicValues, add(32, 288)))
        }

        assertEq(ziskVerifier.programVK(), wireProgramVk);
        assertEq(ziskVerifier.rootCVadcopFinal(), wireRootC);
        assertEq(
            keccak256(abi.encodePacked(ziskVerifier.programVK(), ziskVerifier.rootCVadcopFinal())),
            ziskVerifier.verificationKeyHash()
        );
    }

    function test_realProof_ziskVerifier_accepts() public requiresPlonkVerifier {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(BATCH_COMMITMENT) >> 32;

        assertTrue(ziskVerifier.verify(publicInputs, _ziskSection()));
    }

    function test_realProof_multiProof_type5_accepts() public requiresPlonkVerifier {
        // With previous_hash = 0 and a single public input, the batch public
        // input equals publicInputs[0]; it must be the ZiSK batch commitment
        // truncated by 32 bits. The aggregation verifier is mocked here (see
        // setUp): this test exercises the type-5 decode and the single-batch
        // binding, not the aggregated SNARK check.
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(BATCH_COMMITMENT) >> 32;

        uint256 airbenderLen = 2;
        uint256[] memory ziskSection = _ziskSection();
        uint256[] memory proof = new uint256[](3 + airbenderLen + 34);
        proof[0] = 5; // MULTI_PROOF_TYPE
        proof[1] = 0; // previous_hash
        proof[2] = airbenderLen;
        proof[3] = 111; // placeholder Airbender proof words (mock accepts)
        proof[4] = 222;
        for (uint256 i = 0; i < 34; i++) {
            proof[5 + i] = ziskSection[i];
        }

        assertTrue(multiProofVerifier.verify(publicInputs, proof));
    }

    function test_realProof_tamperedPublics_rejected() public requiresPlonkVerifier {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(BATCH_COMMITMENT) >> 32;

        // Flip one bit of the batch commitment: the digest changes and the
        // pairing check must fail.
        uint256[] memory words = _ziskSection();
        words[25] ^= 1;

        assertFalse(ziskVerifier.verify(publicInputs, words));
    }

    function test_realProof_wrongProgramVk_rejected() public requiresPlonkVerifier {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(BATCH_COMMITMENT) >> 32;

        // A proof for a different guest ELF (different programVK) is refused
        // before any pairing work.
        uint256[] memory words = _ziskSection();
        words[24] ^= 1;

        assertFalse(ziskVerifier.verify(publicInputs, words));
    }

    function test_realProof_wrongVadcopVk_rejected() public requiresPlonkVerifier {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(BATCH_COMMITMENT) >> 32;

        // A proof from a different SNARK circuit generation (different
        // rootCVadcopFinal) is refused before any pairing work.
        uint256[] memory words = _ziskSection();
        words[33] ^= 1;

        assertFalse(ziskVerifier.verify(publicInputs, words));
    }

    function test_realProof_tamperedSnark_rejected() public requiresPlonkVerifier {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(BATCH_COMMITMENT) >> 32;

        // Corrupt a proof scalar (an opening evaluation, so it stays a valid
        // field element): the pairing check must fail.
        uint256[] memory words = _ziskSection();
        words[23] ^= 1;

        assertFalse(ziskVerifier.verify(publicInputs, words));
    }

    function test_realProof_multiProof_wrongBatchInput_rejected() public requiresPlonkVerifier {
        // The Airbender side (mocked to accept) claims a DIFFERENT batch than
        // the ZiSK public values commit to: the cross-proof binding must revert.
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = (uint256(BATCH_COMMITMENT) >> 32) ^ 1;

        uint256 airbenderLen = 2;
        uint256[] memory ziskSection = _ziskSection();
        uint256[] memory proof = new uint256[](3 + airbenderLen + 34);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = airbenderLen;
        for (uint256 i = 0; i < 34; i++) {
            proof[5 + i] = ziskSection[i];
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiProofVerifier.ZiskCommitmentMismatch.selector,
                publicInputs[0],
                uint256(BATCH_COMMITMENT) >> 32
            )
        );
        multiProofVerifier.verify(publicInputs, proof);
    }
}
