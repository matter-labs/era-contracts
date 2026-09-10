// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ISnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/ISnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";

/// @dev Mock verifier that always returns true (Airbender side; exercised with
///      real-proof fixtures elsewhere).
contract MockPassVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev Stand-in for the snarkJS Plonk verifier that accepts iff the single
///      public signal it is handed equals `expectedSignal`. It lets the tests
///      assert the EXACT signal the on-chain reconstruction produces (the
///      digest formula, the sha256 preimage byte order and the field
///      reduction), and name a near-miss signal a real proof could never
///      carry. A wrong reconstruction hands a wrong signal and is rejected.
contract ExpectSignalPlonkVerifier is ISnarkPlonkVerifier {
    uint256 public immutable expectedSignal;

    constructor(uint256 _expectedSignal) {
        expectedSignal = _expectedSignal;
    }

    function verifyProof(uint256[24] calldata, uint256[1] calldata _pubSignals) external view returns (bool) {
        return _pubSignals[0] == expectedSignal;
    }
}

/// @notice THE cross-stack aggregated-range binding vector, pinned verbatim
///         from `zksync-os-zisk/guest-aggregator/BINDING_VECTOR.md` (real
///         4-batch aggregation session, ZiSK v0.18.0, 2026-08-04).
/// @dev Three codebases assert these exact values and must stay in lockstep:
///      the aggregator guest (`cross_stack_binding_vector` host test), the
///      server's aggregation job validation, and this test. Update all pins
///      together whenever any input rotates.
///
///      This suite deploys the REAL ZiskVerifier (whose baked inner programVK /
///      rootCVadcopFinal must equal the vector pins) and drives it through
///      MultiProofVerifier, asserting that the on-chain RECONSTRUCTION of the
///      ZiSK public values reproduces the pinned digest and the expected PLONK
///      signal. The signal stand-in is what lets this suite name the exact
///      expected signal and reject the near-misses below; the real pairing
///      over this vector's aggregated proof is asserted in
///      ZiskVerifierRealProofTest.
contract MultiProofRangeVectorTest is Test {
    /// @dev Inner state-transition guest programVK: the first field of the
    ///      binding digest. It is NOT the aggregated proof's wire [0..32].
    bytes32 internal constant INNER_PROGRAM_VK = 0x44e3d132399c8f3a03ce9672ba0ca00c6503db918731c7ab46d6faea445236ec;
    /// @dev Aggregator guest programVK: the aggregated proof's wire
    ///      public-values bytes [0..32].
    bytes32 internal constant AGGREGATOR_PROGRAM_VK =
        0x4c3d7317a62f651d813ba6afbbce59e45eaa7c009ab2a9b51d2f0fb3e7987254;
    /// @dev Vadcop-final root: the second field of the binding digest, and
    ///      wire public-values bytes [288..320].
    bytes32 internal constant ROOT_C_VADCOP_FINAL = 0xcf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d;

    /// @dev The four per-batch commitments (wire bytes [32..64] of each
    ///      per-batch ZiSK proof), in batch order.
    bytes32 internal constant COMMITMENT_1 = 0x5aa9a30847d37bb20955cfe6a65c916d4d0c504c8e5bb0965db8a90aba1e9938;
    bytes32 internal constant COMMITMENT_2 = 0x167bf6f9edbe48835b6b60e98af53552b0126765a804b86a3d7749daf05a5f4e;
    bytes32 internal constant COMMITMENT_3 = 0x8f03a8b3b8b78ef7ab5004817c9ebf211b09533b9a0ad86440396f4605ab794b;
    bytes32 internal constant COMMITMENT_4 = 0x3db0606d441cb57e9c621be9052e759db43e7c5c608c6e810ce673d9a4503c45;

    /// @dev `_computeZKsyncOSHash(0, PIs)` over the four public inputs.
    bytes32 internal constant CHAINED_PI = 0x0000000076b405f665d8b8b9c069b298656c9ef179632673523db317aeaa88b6;
    /// @dev keccak256(INNER_PROGRAM_VK || ROOT_C_VADCOP_FINAL || CHAINED_PI):
    ///      the aggregated proof's public-values bytes [32..64].
    bytes32 internal constant DIGEST = 0x8d3dc379548b65d0ed7df762dc646bf46fdbdf628cfe483479392ea8159e405b;

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    MultiProofVerifier internal verifier;
    ZiskVerifier internal ziskVerifier;

    function setUp() public {
        // The range verifier is the REAL ZiskVerifier. It reconstructs the ZiSK
        // public values from its own pins; the Plonk stand-in accepts iff the
        // reconstructed signal equals the one this vector implies.
        ziskVerifier = new ZiskVerifier(ISnarkPlonkVerifier(address(new ExpectSignalPlonkVerifier(_expectedSignal()))));
        verifier = new MultiProofVerifier(IVerifier(address(new MockPassVerifier())), address(this));
        verifier.setZiskRangeVerifier(IVerifier(address(ziskVerifier)));
    }

    /// @dev The per-batch public inputs as L1 consumes them: each commitment
    ///      read as a big-endian uint256, right-shifted 32 bits.
    function _publicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](4);
        pis[0] = uint256(COMMITMENT_1) >> 32;
        pis[1] = uint256(COMMITMENT_2) >> 32;
        pis[2] = uint256(COMMITMENT_3) >> 32;
        pis[3] = uint256(COMMITMENT_4) >> 32;
    }

    /// @dev The single PLONK public signal the on-chain reconstruction must
    ///      produce for the pinned range: sha256 over the reconstructed
    ///      320-byte preimage (aggregatorProgramVK || DIGEST || 224 zeros ||
    ///      rootCVadcopFinal), reduced mod the BN254 scalar field. The wire
    ///      carries the AGGREGATOR pin; the INNER pin is inside DIGEST.
    function _expectedSignal() internal pure returns (uint256) {
        bytes memory preimage = abi.encodePacked(AGGREGATOR_PROGRAM_VK, DIGEST, new bytes(224), ROOT_C_VADCOP_FINAL);
        require(preimage.length == 320, "preimage length");
        return uint256(sha256(preimage)) % RFIELD;
    }

    /// @dev The signal a verifier would produce with the two program VK pins
    ///      exchanged: the inner pin on the wire, the aggregator pin inside the
    ///      digest. The real reconstruction must never produce this signal.
    function _swappedPinSignal() internal pure returns (uint256) {
        bytes32 swappedDigest = keccak256(abi.encodePacked(AGGREGATOR_PROGRAM_VK, ROOT_C_VADCOP_FINAL, CHAINED_PI));
        bytes memory preimage = abi.encodePacked(INNER_PROGRAM_VK, swappedDigest, new bytes(224), ROOT_C_VADCOP_FINAL);
        require(preimage.length == 320, "preimage length");
        return uint256(sha256(preimage)) % RFIELD;
    }

    /// @dev Build a type-5 proof with an opaque 24-word ZiSK SNARK section (the
    ///      reconstruction never reads it).
    function _rangeProof(uint256 _previousHash) internal pure returns (uint256[] memory proof) {
        uint256 airbenderLen = 2;
        proof = new uint256[](3 + airbenderLen + 24);
        proof[0] = 5; // MULTI_PROOF_TYPE
        proof[1] = _previousHash;
        proof[2] = airbenderLen;
    }

    /// @dev The pinned chain trace and digest formula, replayed step by step.
    function test_bindingVector_formula() public pure {
        uint256[] memory pis = _publicInputs();

        // result = PI[0]  (initialHash == 0: the first PI enters unhashed)
        uint256 result = pis[0];
        for (uint256 i = 1; i < pis.length; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, pis[i]))) >> 32;
        }
        assertEq(bytes32(result), CHAINED_PI, "chainedPI");

        assertEq(
            keccak256(abi.encodePacked(INNER_PROGRAM_VK, ROOT_C_VADCOP_FINAL, CHAINED_PI)),
            DIGEST,
            "binding digest"
        );
    }

    /// @dev The deployed ZiskVerifier's baked pins must equal the vector — the
    ///      reconstruction rebuilds the digest and the wire from THEM, so any
    ///      drift breaks the whole binding.
    function test_ziskVerifier_pinsMatchVector() public view {
        assertEq(ziskVerifier.innerProgramVK(), INNER_PROGRAM_VK, "innerProgramVK pin");
        assertEq(ziskVerifier.aggregatorProgramVK(), AGGREGATOR_PROGRAM_VK, "aggregatorProgramVK pin");
        assertEq(ziskVerifier.rootCVadcopFinal(), ROOT_C_VADCOP_FINAL, "rootCVadcopFinal pin");
    }

    /// @dev The two guest programs are different ELFs, so the two pins must
    ///      hold different values. Equal pins would hide a swapped pin.
    function test_ziskVerifier_programVkPinsDiffer() public view {
        assertTrue(ziskVerifier.innerProgramVK() != ziskVerifier.aggregatorProgramVK(), "program VK pins must differ");
    }

    /// @dev The contract's own reconstruction (chainedPI -> digest -> preimage
    ///      -> sha256 -> signal) reproduces the pinned vector exactly: the
    ///      ExpectSignal Plonk stand-in accepts only that signal.
    function test_bindingVector_reconstructsSignal_accepts() public view {
        assertTrue(verifier.verify(_publicInputs(), _rangeProof(0)));
    }

    /// @dev Self-contained seed: a nonzero Airbender previous_hash continuation
    ///      does not change the reconstructed ZiSK signal (the ZiSK chain is
    ///      always seed-0), so the same signal is produced and accepted.
    function test_bindingVector_previousHashContinuation_accepts() public view {
        uint256 previousHash = uint256(keccak256("earlier range")) >> 32;
        assertTrue(verifier.verify(_publicInputs(), _rangeProof(previousHash)));
    }

    /// @dev Any change to the range's public inputs changes the reconstructed
    ///      digest -> signal, so the pinned-signal stand-in rejects it: the
    ///      binding is inherent, no separate commitment word to check.
    function test_bindingVector_tamperedBatch_rejected() public {
        uint256[] memory pis = _publicInputs();
        pis[2] ^= 1;

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        verifier.verify(pis, _rangeProof(0));
    }

    /// @dev The two program VK pins have one role each and are not
    ///      interchangeable. A stand-in that expects the swapped-pin signal
    ///      (inner pin on the wire, aggregator pin in the digest) is rejected,
    ///      because the reconstruction puts each pin in its own place.
    function test_swappedProgramVkPins_rejected() public {
        ZiskVerifier swappedExpectation = new ZiskVerifier(
            ISnarkPlonkVerifier(address(new ExpectSignalPlonkVerifier(_swappedPinSignal())))
        );

        assertTrue(_swappedPinSignal() != _expectedSignal(), "swap must change the signal");
        assertFalse(swappedExpectation.verify(_publicInputs(), _ziskSnarkWords()));
    }

    /// @dev The 24 opaque SNARK words, as MultiProofVerifier hands them to the
    ///      range verifier (the header is already stripped).
    function _ziskSnarkWords() internal pure returns (uint256[] memory words) {
        words = new uint256[](24);
    }
}
