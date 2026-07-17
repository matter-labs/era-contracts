// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IZiskVerifier} from "contracts/state-transition/chain-interfaces/IZiskVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";

/// @dev Mock verifier that always returns true (Airbender + aggregated-SNARK
///      sides; both are exercised with real-proof fixtures elsewhere).
contract MockPassVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev Mock per-batch ZiSK verifier exposing the vector's wire-form pins.
contract MockZiskPinsVerifier is IZiskVerifier {
    bytes32 public immutable programVKPin;
    bytes32 public immutable rootCPin;

    constructor(bytes32 _programVK, bytes32 _rootC) {
        programVKPin = _programVK;
        rootCPin = _rootC;
    }

    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external view returns (bytes32) {
        return keccak256(abi.encodePacked(programVKPin, rootCPin));
    }

    function programVK() external view returns (bytes32) {
        return programVKPin;
    }

    function rootCVadcopFinal() external view returns (bytes32) {
        return rootCPin;
    }
}

/// @notice THE cross-stack aggregated-range binding vector, pinned verbatim
///         from `zksync-os-zisk/guest-aggregator/BINDING_VECTOR.md` (real
///         4-batch aggregation session, ZiSK v0.18.0, 2026-07-15).
/// @dev Three codebases assert these exact values and must stay in lockstep:
///      the aggregator guest (`cross_stack_binding_vector` host test), the
///      server's aggregation job validation, and this test. Update all pins
///      together whenever any input rotates.
contract MultiProofRangeVectorTest is Test {
    /// @dev STF guest programVK: wire public-values bytes [0..32].
    bytes32 internal constant INNER_PROGRAM_VK =
        0x481748830df5c3b7aa5522333ace2c4b533352637b92fd3c83ecc506c5104ead;
    /// @dev Vadcop-final root: wire public-values bytes [288..320].
    bytes32 internal constant ROOT_C_VADCOP_FINAL =
        0xcf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d;

    /// @dev The four per-batch commitments (wire bytes [32..64] of each
    ///      per-batch ZiSK proof), in batch order.
    bytes32 internal constant COMMITMENT_1 =
        0x95693fd871251f2a04f558f94852d31d4f7b0cd38b0ee2c746bd2851dc701dca;
    bytes32 internal constant COMMITMENT_2 =
        0x4962160e4e0addc72fe2178dbbf3c5882ca1033790bb968d4fa451485987f99b;
    bytes32 internal constant COMMITMENT_3 =
        0xe697864dd72ddded6f1818db6618efff8e695714db8492ac50abc9f5d8b6221e;
    bytes32 internal constant COMMITMENT_4 =
        0x3cbda79d374329af945a0b1d2d73c87b2cd2cadb69ab3d6c03166a690dfff898;

    /// @dev `_computeZKsyncOSHash(0, PIs)` over the four public inputs.
    bytes32 internal constant CHAINED_PI =
        0x000000004e755bc20431285db82f02b677f0fa43b0b4ae7298e2f489e1a45b78;
    /// @dev keccak256(INNER_PROGRAM_VK || ROOT_C_VADCOP_FINAL || CHAINED_PI):
    ///      the aggregated proof's public-values bytes [32..64].
    bytes32 internal constant DIGEST =
        0x5f47db9b336cf84b7b7fc49ca77eadb5160e373dc8f12057d719f45d3b2fbd84;

    MultiProofVerifier internal verifier;

    function setUp() public {
        verifier = new MultiProofVerifier(
            IVerifier(address(new MockPassVerifier())),
            IVerifier(address(new MockZiskPinsVerifier(INNER_PROGRAM_VK, ROOT_C_VADCOP_FINAL))),
            address(this)
        );
        verifier.setZiskRangeVerifier(IVerifier(address(new MockPassVerifier())));
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

    /// @dev Build a type-5 proof whose ZiSK public-values word 1 is `digest`.
    function _rangeProof(uint256 _previousHash, uint256 _digest) internal pure returns (uint256[] memory proof) {
        uint256 airbenderLen = 2;
        proof = new uint256[](3 + airbenderLen + 34);
        proof[0] = 5; // MULTI_PROOF_TYPE
        proof[1] = _previousHash;
        proof[2] = airbenderLen;
        proof[5 + 25] = _digest;
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

    /// @dev The contract accepts the pinned digest for the pinned range —
    ///      i.e. its own pin-readback + _computeZKsyncOSHash path reproduces
    ///      the vector exactly.
    function test_bindingVector_verify_accepts() public view {
        assertTrue(verifier.verify(_publicInputs(), _rangeProof(0, uint256(DIGEST))));
    }

    /// @dev Self-contained seed: a nonzero Airbender previous_hash
    ///      continuation does not change the expected ZiSK digest.
    function test_bindingVector_previousHashContinuation_accepts() public view {
        uint256 previousHash = uint256(keccak256("earlier range")) >> 32;
        assertTrue(verifier.verify(_publicInputs(), _rangeProof(previousHash, uint256(DIGEST))));
    }

    /// @dev Any change to the range's public inputs breaks the binding.
    function test_bindingVector_tamperedBatch_rejected() public {
        uint256[] memory pis = _publicInputs();
        pis[2] ^= 1;

        // The digest the tampered range would need instead.
        uint256 result = pis[0];
        for (uint256 i = 1; i < pis.length; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, pis[i]))) >> 32;
        }
        uint256 tamperedDigest = uint256(
            keccak256(abi.encodePacked(INNER_PROGRAM_VK, ROOT_C_VADCOP_FINAL, bytes32(result)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiProofVerifier.ZiskRangeDigestMismatch.selector,
                tamperedDigest,
                uint256(DIGEST)
            )
        );
        verifier.verify(pis, _rangeProof(0, uint256(DIGEST)));
    }
}
