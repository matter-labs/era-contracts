// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
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
/// `eravm-prover-host prove-snark` against the regenerated `L1VerifierPlonk`
/// (whose `_loadVerificationKey` was rewritten from the matching `snark_vk.json`).
/// Exercises both the standalone `L1VerifierPlonk.verify` path and the
/// airbender slot of `DualVerifier`'s router.
contract AirbenderPlonkProofIntegrationTest is Test {
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    /// Program output the guest emitted, as 8 BE u32 words. This is the
    /// `proof_public_input` from `eravm-airbender-verifier` for batch 506093 —
    /// the full keccak(prev_commitment ‖ curr_commitment), packed `[u32; 8]`.
    uint32[8] internal PROGRAM_OUTPUT = [
        uint32(1130987272), 3890202368, 1477174677, 3755385212,
        2290908159, 161842629, 2088189254, 3910592463
    ];

    /// Commitment to the eravm-airbender-verifier guest binary, as the
    /// wrapper sees it. Sourced from `recursion_chain_hash` in the FRI proof
    /// for batch 506093 (also surfaced as `aux_params` of
    /// `zkos-wrapper`'s `BinaryCommitment`). For now the value is just pinned
    /// here from the artifact; the production wiring is for L1 to either bake
    /// in the audited binary's commitment or fetch it from a registry.
    uint32[8] internal BINARY_COMMITMENT = [
        uint32(1510299098), 4057252708, 2938844326, 4124090251,
        2485515716, 1206552808, 429924834, 1342631824
    ];

    L1VerifierPlonk internal airbenderVerifier;
    DualVerifier internal dual;

    function setUp() public {
        airbenderVerifier = new L1VerifierPlonk();
        dual = new DualVerifier(
            IVerifierV2(address(new InertFflonkVerifier())),
            IVerifier(address(new InertPlonkVerifier())),
            IVerifier(address(airbenderVerifier))
        );
    }

    /// Sanity-check: the airbender PLONK verifier accepts the real proof when
    /// called directly, with no router in front.
    function test_l1VerifierPlonk_acceptsAirbenderProof() public view {
        bool ok = airbenderVerifier.verify(
            AirbenderPlonkProofFixture.publicInputs(),
            AirbenderPlonkProofFixture.serializedProof()
        );
        assertTrue(ok, "L1VerifierPlonk should accept the airbender proof directly");
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
    /// equal the one baked into `L1VerifierPlonk` by codegen — i.e. the test
    /// is checking the new VK, not a stale one.
    function test_dualVerifier_airbenderVkHash_matchesUnderlyingVerifier() public view {
        bytes32 viaDual = dual.verificationKeyHash(AIRBENDER_PLONK_VERIFICATION_TYPE);
        bytes32 viaDirect = airbenderVerifier.verificationKeyHash();
        assertEq(viaDual, viaDirect, "DualVerifier should surface the airbender slot's VK hash");
    }

    /// The VK hash baked into `L1VerifierPlonk` by codegen — recorded in the
    /// header comment of the regenerated contract. Pinning it here catches
    /// accidental regenerations from the wrong key.
    function test_l1VerifierPlonk_vkHashIsPinned() public view {
        bytes32 expected = 0xac82c63fb5cbb3cfa3fa0d8c9a98926477687080bea1a10917a5f9ac83c012f7;
        assertEq(airbenderVerifier.verificationKeyHash(), expected, "VK hash drifted from codegen output");
    }

    // -------------------------------------------------------------------------------------------
    // Negative tests: prove the verifier is doing real cryptographic work, not a stub. If `verify`
    // returned `true` for arbitrary inputs, none of the cases below would revert.
    // -------------------------------------------------------------------------------------------

    /// Tampering with the public input by a single bit must invalidate the proof.
    function test_l1VerifierPlonk_rejectsTamperedPublicInput() public {
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
    function test_l1VerifierPlonk_rejectsTamperedProof() public {
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
    function test_l1VerifierPlonk_rejectsMalformedCurvePoint() public {
        uint256[] memory proof = AirbenderPlonkProofFixture.serializedProof();
        // Zero out the first commitment's (x, y); `loadProof` rejects (0, 0).
        proof[0] = 0;
        proof[1] = 0;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        airbenderVerifier.verify(AirbenderPlonkProofFixture.publicInputs(), proof);
    }

    // -------------------------------------------------------------------------------------------
    // Full L1-side derivation: compute the SNARK public input from
    // `(program_output, binary_commitment)` and feed it to the verifier — exactly the flow the
    // production settlement contract has to perform. No magic constants from the proof JSON in
    // the verify call.
    // -------------------------------------------------------------------------------------------

    /// Pack a `uint32[8]` as 32 little-endian bytes. The wrapper hashes both
    /// `program_output` and `binary_commitment` in this order.
    function _leBytes(uint32[8] memory words) internal pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i = 0; i < 8; i++) {
            uint32 w = words[i];
            out[i * 4 + 0] = bytes1(uint8(w));
            out[i * 4 + 1] = bytes1(uint8(w >> 8));
            out[i * 4 + 2] = bytes1(uint8(w >> 16));
            out[i * 4 + 3] = bytes1(uint8(w >> 24));
        }
    }

    /// Cross-check: the SNARK's claimed public input equals the wrapper's
    /// derivation `keccak(program_output ‖ binary_commitment) >> 32`. If this
    /// drifts, either our encoding understanding is wrong or the proof was
    /// produced against different program/binary than we think.
    function test_publicInput_isKeccakOfProgramOutputAndBinaryCommitment() public view {
        bytes memory preimage = abi.encodePacked(_leBytes(PROGRAM_OUTPUT), _leBytes(BINARY_COMMITMENT));
        uint256 derived = uint256(keccak256(preimage)) >> 32;

        uint256 fromFixture = AirbenderPlonkProofFixture.publicInputs()[0];
        assertEq(derived, fromFixture, "Derived public input doesn't match SNARK fixture");
    }

    /// End-to-end: derive the public input on-chain from raw program output +
    /// binary commitment, build a single-element `uint256[]`, and verify the
    /// SNARK proof against it. This is the shape the L1 settlement contract
    /// will ultimately use.
    function test_endToEnd_derivePublicInputThenVerify() public view {
        bytes memory preimage = abi.encodePacked(_leBytes(PROGRAM_OUTPUT), _leBytes(BINARY_COMMITMENT));
        uint256 derived = uint256(keccak256(preimage)) >> 32;

        uint256[] memory inputs = new uint256[](1);
        inputs[0] = derived;

        bool ok = airbenderVerifier.verify(inputs, AirbenderPlonkProofFixture.serializedProof());
        assertTrue(ok, "Proof must verify against the derived public input");
    }
}
