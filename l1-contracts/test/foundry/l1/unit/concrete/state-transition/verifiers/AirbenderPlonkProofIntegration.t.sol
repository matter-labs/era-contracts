// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {AirbenderVerifierPlonk} from "contracts/state-transition/verifiers/AirbenderVerifierPlonk.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";

import {AirbenderPlonkProofFixture} from "./fixtures/AirbenderPlonkProofFixture.sol";

/// @notice Stand-in for the FFLONK slot of `DualVerifier`. We never route to it
/// from these tests, so it's free to fail-closed.
contract InertFflonkVerifier is IVerifierV2 {
    function verify(uint256[] calldata, uint256[] calldata) external pure override returns (bool) {
        return false;
    }

    function verificationKeyHash() external pure override returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Stand-in for the Boojum PLONK slot of `DualVerifier`. Same rationale
/// as `InertFflonkVerifier`.
contract InertPlonkVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure override returns (bool) {
        return false;
    }

    function verificationKeyHash() external pure override returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Verifies a real airbender PLONK SNARK proof produced by
/// `eravm-prover-host prove-snark` against the regenerated `AirbenderVerifierPlonk`
/// (generated from the matching `snark_vk.json` by
/// `tools/verifier-gen/regenerate-airbender-verifier.sh`).
/// Exercises both the standalone `AirbenderVerifierPlonk.verify` path and the
/// airbender slot of `DualVerifier`'s router.
contract AirbenderPlonkProofIntegrationTest is Test {
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    /// Commitment to the eravm-airbender-verifier guest binary, as the wrapper
    /// sees it. Sourced from `recursion_chain_hash` in the FRI proof for batch 1
    /// (the guest's final registers 18..=25; also surfaced as `aux_params` of
    /// `zkos-wrapper`'s `BinaryCommitment`). The recursion circuit constrains
    /// these registers to the audited binary, so the binary commitment is bound
    /// *inside* the proof — it is NOT part of the SNARK public input. Pinned here
    /// only to document the value the proof was produced against.
    uint32[8] internal BINARY_COMMITMENT = [
        uint32(3178311086),
        1416018931,
        3804989641,
        3067714877,
        3539870970,
        3742360073,
        2234587709,
        3179844674
    ];

    AirbenderVerifierPlonk internal airbenderVerifier;
    EraDualVerifier internal dual;

    function setUp() public {
        airbenderVerifier = new AirbenderVerifierPlonk();
        dual = new EraDualVerifier(
            IVerifierV2(address(new InertFflonkVerifier())),
            IVerifier(address(new InertPlonkVerifier())),
            IVerifier(address(airbenderVerifier))
        );
    }

    /// Sanity-check: the airbender PLONK verifier accepts the real proof when
    /// called directly, with no router in front.
    function test_airbenderVerifierPlonk_acceptsAirbenderProof() public view {
        bool ok = airbenderVerifier.verify(
            AirbenderPlonkProofFixture.publicInputs(),
            AirbenderPlonkProofFixture.serializedProof()
        );
        assertTrue(ok, "AirbenderVerifierPlonk should accept the airbender proof directly");
    }

    /// Routing test: `DualVerifier` should dispatch a proof prefixed with
    /// verifier-type 2 to the airbender slot, which then accepts the proof.
    function test_dualVerifier_routesAirbenderProof() public view {
        uint256[] memory inner = AirbenderPlonkProofFixture.serializedProof();
        uint256[] memory withType = new uint256[](inner.length + 1);
        withType[0] = AIRBENDER_PLONK_VERIFICATION_TYPE;
        for (uint256 i = 0; i < inner.length; i++) {
            withType[i + 1] = inner[i];
        }

        bool ok = dual.verify(AirbenderPlonkProofFixture.publicInputs(), withType);
        assertTrue(ok, "DualVerifier should accept airbender-tagged proof");
    }

    /// The airbender slot's VK hash, surfaced through `DualVerifier`, must
    /// equal the one baked into `AirbenderVerifierPlonk` by codegen — i.e. the test
    /// is checking the new VK, not a stale one.
    function test_dualVerifier_airbenderVkHash_matchesUnderlyingVerifier() public view {
        bytes32 viaDual = dual.verificationKeyHash(AIRBENDER_PLONK_VERIFICATION_TYPE);
        bytes32 viaDirect = airbenderVerifier.verificationKeyHash();
        assertEq(viaDual, viaDirect, "DualVerifier should surface the airbender slot's VK hash");
    }

    /// The VK hash baked into `AirbenderVerifierPlonk` by codegen — recorded in the
    /// header comment of the regenerated contract. Pinning it here catches
    /// accidental regenerations from the wrong key. This value is the codegen
    /// output for the `snark_vk.json` of the verifier release pinned in
    /// `airbender_prover_server/Cargo.toml` (`eravm-airbender-verifier-v31.3.0`);
    /// regenerate the contract with
    /// `tools/verifier-gen/regenerate-airbender-verifier.sh` and update this pin
    /// whenever that release moves.
    function test_airbenderVerifierPlonk_vkHashIsPinned() public view {
        bytes32 expected = 0x43ae7f55acdf83f070c9c0d317f1e83036c36c1070aae346476ebe9bef18281c;
        assertEq(airbenderVerifier.verificationKeyHash(), expected, "VK hash drifted from codegen output");
    }

    // -------------------------------------------------------------------------------------------
    // Negative tests: prove the verifier is doing real cryptographic work, not a stub. If `verify`
    // returned `true` for arbitrary inputs, none of the cases below would revert.
    // -------------------------------------------------------------------------------------------

    /// Tampering with the public input by a single bit must invalidate the proof.
    function test_airbenderVerifierPlonk_rejectsTamperedPublicInput() public {
        uint256[] memory inputs = AirbenderPlonkProofFixture.publicInputs();
        inputs[0] ^= 1;

        // The PLONK verifier reverts (rather than returning false) when the
        // pairing identity that would prove the public-input commitment fails.
        // We don't pin the exact revert reason: depending on which byte we flip,
        // the proof may fail in the cheap structural check (`loadProof`) or in
        // the pairing/quotient check. Either is fine — both prove the verifier
        // rejected the tamper.
        vm.expectRevert();
        airbenderVerifier.verify(inputs, AirbenderPlonkProofFixture.serializedProof());
    }

    /// Tampering with the proof itself must invalidate verification.
    function test_airbenderVerifierPlonk_rejectsTamperedProof() public {
        uint256[] memory proof = AirbenderPlonkProofFixture.serializedProof();
        // Flip a low bit of an opening evaluation — these live near the end of
        // the serialized proof and reach the pairing check rather than the
        // cheaper structural validation in `loadProof`.
        proof[proof.length - 1] ^= 1;

        // We don't pin the exact revert reason: depending on which byte we flip,
        // the proof may fail in the cheap structural check (`loadProof`) or in
        // the pairing/quotient check. Either is fine — both prove the verifier
        // rejected the tamper.
        vm.expectRevert();
        airbenderVerifier.verify(AirbenderPlonkProofFixture.publicInputs(), proof);
    }

    /// Sanity-check that mutating one of the curve-point coordinates near the
    /// front of the proof trips `loadProof`'s structural validation. If the
    /// verifier were a no-op, nothing here would revert.
    function test_airbenderVerifierPlonk_rejectsMalformedCurvePoint() public {
        uint256[] memory proof = AirbenderPlonkProofFixture.serializedProof();
        // Zero out the first commitment's (x, y); `loadProof` rejects (0, 0).
        proof[0] = 0;
        proof[1] = 0;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        airbenderVerifier.verify(AirbenderPlonkProofFixture.publicInputs(), proof);
    }

    // -------------------------------------------------------------------------------------------
    // Full L1-side derivation: compute the SNARK public input from `program_output` and feed it to
    // the verifier — exactly the flow the production settlement contract has to perform. No magic
    // constants from the proof JSON in the verify call.
    // -------------------------------------------------------------------------------------------

    /// Derive the single SNARK public input from `program_output`, exactly as
    /// the wrapper does: pack the 8 u32 words little-endian into 32 bytes (RISC-V
    /// registers are little-endian), read them big-endian, and drop the low 32
    /// bits (`PUBLIC_INPUT_SHIFT`; BN254's scalar field is ~254 bits). No keccak
    /// and no binary commitment enter here — the guest already hashed the batch
    /// commitments into `program_output`, and the binary commitment is bound
    /// inside the recursion circuit rather than exposed as a public input.
    function _derivePublicInput(uint32[8] memory words) internal pure returns (uint256) {
        bytes memory le = new bytes(32);
        for (uint256 i = 0; i < 8; i++) {
            uint32 w = words[i];
            le[i * 4 + 0] = bytes1(uint8(w));
            le[i * 4 + 1] = bytes1(uint8(w >> 8));
            le[i * 4 + 2] = bytes1(uint8(w >> 16));
            le[i * 4 + 3] = bytes1(uint8(w >> 24));
        }
        uint256 packed;
        assembly {
            packed := mload(add(le, 32))
        }
        return packed >> 32;
    }

    /// Cross-check: the SNARK's claimed public input equals the wrapper's
    /// derivation from `programOutput()` alone. Both come from the fixture
    /// generator, so this pins the Solidity encoding (`_derivePublicInput`) against
    /// the Rust one — if the little-endian packing or `PUBLIC_INPUT_SHIFT` drift on
    /// either side, this fails.
    function test_publicInput_isShiftedProgramOutput() public view {
        uint256 derived = _derivePublicInput(AirbenderPlonkProofFixture.programOutput());

        uint256 fromFixture = AirbenderPlonkProofFixture.publicInputs()[0];
        assertEq(derived, fromFixture, "Derived public input doesn't match SNARK fixture");
    }

    /// End-to-end: derive the public input on-chain from the raw program output,
    /// build a single-element `uint256[]`, and verify the SNARK proof against it.
    /// This is the shape the L1 settlement contract ultimately uses.
    function test_endToEnd_derivePublicInputThenVerify() public view {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = _derivePublicInput(AirbenderPlonkProofFixture.programOutput());

        bool ok = airbenderVerifier.verify(inputs, AirbenderPlonkProofFixture.serializedProof());
        assertTrue(ok, "Proof must verify against the derived public input");
    }
}
