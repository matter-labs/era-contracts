// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IZiskSnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/IZiskSnarkPlonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {NonZeroCarriedHash} from "contracts/common/L1ContractErrors.sol";
import {PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

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
contract ExpectSignalPlonkVerifier is IZiskSnarkPlonkVerifier {
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
/// @dev STALE: this vector is a ZiSK v0.18.0 session, so its program VK pins
///      disagree with the deployed verifier and the suite is red. The
///      `fixture-session` workflow produces the ZiSK v1.2.0-alpha replacement.
///      Every value below rotates together, because they come from one
///      session.
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
    bytes32 internal constant INNER_PROGRAM_VK = 0x8168c5d383a50a9c7a40561b82bf679cc6dfdab0308417b4fea653362d78d080;
    /// @dev Aggregator guest programVK: the aggregated proof's wire
    ///      public-values bytes [0..32].
    bytes32 internal constant AGGREGATOR_PROGRAM_VK =
        0xf68b9862e424e377af7b4220a419ce45bc52ce70b0a37aea486a15a5ca38b738;
    /// @dev Vadcop-final root: the second field of the binding digest, and
    ///      wire public-values bytes [544..576].
    bytes32 internal constant ROOT_C_VADCOP_FINAL = 0xcf2a309856f107b143836ada112806da71ae11567fa3f2d2050baba5381c7b7d;

    /// @dev The four per-batch commitments (the first eight guest-public slots
    ///      of each per-batch ZiSK proof), in batch order.
    bytes32 internal constant COMMITMENT_1 = 0x63c7606faee0ee9eff230fec391e64c0c82a0277947973ce7f6f1c9088c821dd;
    bytes32 internal constant COMMITMENT_2 = 0x7d6a5ed6ffda210164c11dd6f6fccbd35c4ff70632e845a5bf256e3ec48940b9;
    bytes32 internal constant COMMITMENT_3 = 0xd5a7b4485d1aece18348655132e73c86b23fa0f251adb173f80123d05a914f15;
    bytes32 internal constant COMMITMENT_4 = 0xc5ed165443011bac65df4d0f4240de3429c033996e9fce630a631e117537cd61;

    /// @dev The range public input over the four batches: one keccak over the
    ///      concatenated untruncated commitments, shifted once, as the
    ///      settlement layer and the aggregator guest both compute it.
    bytes32 internal constant CHAINED_PI = 0x00000000108311cf154dafcd8fbeb3d29ff924941d60db59f523d33baa5d2ca5;
    /// @dev keccak256(INNER_PROGRAM_VK || ROOT_C_VADCOP_FINAL || CHAINED_PI):
    ///      the aggregated proof carries it across the first eight guest-public
    ///      slots, public-values bytes [32..96].
    bytes32 internal constant DIGEST = 0xf29341c341f2622ba86a21bbb36dde9742e1983e531c278fd1cee04c6f823e2c;

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev Byte length of the ZiSK guest-publics section: 64 u64 slots.
    uint256 internal constant GUEST_PUBLICS_BYTES = 512;
    /// @dev Byte length of the ZiSK public-values preimage: the guest-publics
    ///      section between the two 32-byte pins.
    uint256 internal constant PUBLIC_VALUES_BYTES = 64 + GUEST_PUBLICS_BYTES;

    MultiProofVerifier internal verifier;
    ZiskVerifier internal ziskVerifier;

    /// @dev The verifier reads the requirement from its caller, which in
    ///      production is the chain's diamond. The test contract calls it
    ///      directly, so it stands in for that chain.
    bool internal ziskDisabled;

    function ziskVerificationDisabled() external view returns (bool) {
        return ziskDisabled;
    }

    function setUp() public {
        // The range verifier is the REAL ZiskVerifier. It reconstructs the ZiSK
        // public values from its own pins; the Plonk stand-in accepts iff the
        // reconstructed signal equals the one this vector implies.
        ziskVerifier = new ZiskVerifier(
            IZiskSnarkPlonkVerifier(address(new ExpectSignalPlonkVerifier(_expectedSignal())))
        );
        verifier = new MultiProofVerifier(IVerifier(address(new MockPassVerifier())), IVerifier(address(ziskVerifier)));
    }

    /// @dev The per-batch public inputs as L1 consumes them: each commitment
    ///      read as a big-endian uint256, right-shifted 32 bits.
    /// @dev The Executor supplies the batch public inputs untruncated. The
    ///      fold shifts once, at the end, so the commitments enter whole.
    function _publicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](4);
        pis[0] = uint256(COMMITMENT_1);
        pis[1] = uint256(COMMITMENT_2);
        pis[2] = uint256(COMMITMENT_3);
        pis[3] = uint256(COMMITMENT_4);
    }

    /// @dev The guest-publics section that carries `_digest`: 64 little-endian
    ///      u64 slots, one per guest public. A guest public holds a 32-bit
    ///      value, so a slot takes four digest bytes and four zero pad bytes.
    ///      The digest fills the first eight slots and the aggregator guest
    ///      leaves the rest zero. Spelled out byte by byte here, so it checks
    ///      the verifier's word arithmetic rather than repeating it.
    function _guestPublics(bytes32 _digest) internal pure returns (bytes memory publics) {
        publics = new bytes(GUEST_PUBLICS_BYTES);
        for (uint256 slot = 0; slot < 8; ++slot) {
            for (uint256 offset = 0; offset < 4; ++offset) {
                publics[slot * 8 + offset] = _digest[slot * 4 + offset];
            }
        }
    }

    /// @dev The single PLONK public signal the on-chain reconstruction must
    ///      produce for the pinned range: sha256 over the reconstructed
    ///      576-byte preimage (aggregatorProgramVK || guest publics carrying
    ///      DIGEST || rootCVadcopFinal), reduced mod the BN254 scalar field.
    ///      The wire carries the AGGREGATOR pin; the INNER pin is inside
    ///      DIGEST.
    function _expectedSignal() internal pure returns (uint256) {
        bytes memory preimage = abi.encodePacked(AGGREGATOR_PROGRAM_VK, _guestPublics(DIGEST), ROOT_C_VADCOP_FINAL);
        require(preimage.length == PUBLIC_VALUES_BYTES, "preimage length");
        return uint256(sha256(preimage)) % RFIELD;
    }

    /// @dev The signal a verifier would produce with the two program VK pins
    ///      exchanged: the inner pin on the wire, the aggregator pin inside the
    ///      digest. The real reconstruction must never produce this signal.
    function _swappedPinSignal() internal pure returns (uint256) {
        bytes32 swappedDigest = keccak256(abi.encodePacked(AGGREGATOR_PROGRAM_VK, ROOT_C_VADCOP_FINAL, CHAINED_PI));
        bytes memory preimage = abi.encodePacked(INNER_PROGRAM_VK, _guestPublics(swappedDigest), ROOT_C_VADCOP_FINAL);
        require(preimage.length == PUBLIC_VALUES_BYTES, "preimage length");
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

        // One keccak over the concatenation, one shift at the end.
        uint256 result = uint256(keccak256(abi.encodePacked(pis))) >> 32;
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

    /// @dev The settlement layer carries no continuation input, so the carried
    ///      hash slot is reserved. A range that fills it is refused before
    ///      either sub-verifier runs.
    function test_bindingVector_nonZeroCarriedHash_rejected() public {
        uint256 carriedHash = uint256(keccak256("earlier range")) >> 32;

        vm.expectRevert(NonZeroCarriedHash.selector);
        verifier.verify(_publicInputs(), _rangeProof(carriedHash));
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

    /// @dev The reconstruction spreads the binding digest over the first eight
    ///      guest-public slots. Driven by the deployed verifier's OWN pins, so
    ///      it holds the layout independently of the pinned vector above. The
    ///      near miss is a digest written as 32 contiguous bytes: the signal a
    ///      reconstruction that ignores the u64 slot width would produce.
    function test_reconstruction_spreadsDigestOverGuestPublics() public {
        uint256[] memory pis = _publicInputs();
        bytes32 rootC = ziskVerifier.rootCVadcopFinal();
        bytes32 chainedPi = bytes32(uint256(keccak256(abi.encodePacked(pis))) >> PUBLIC_INPUT_SHIFT);
        bytes32 digest = keccak256(abi.encodePacked(ziskVerifier.innerProgramVK(), rootC, chainedPi));
        bytes32 aggregatorVk = ziskVerifier.aggregatorProgramVK();

        uint256 spreadSignal = uint256(sha256(abi.encodePacked(aggregatorVk, _guestPublics(digest), rootC))) % RFIELD;
        uint256 contiguousSignal = uint256(
            sha256(abi.encodePacked(aggregatorVk, digest, new bytes(GUEST_PUBLICS_BYTES - 32), rootC))
        ) % RFIELD;
        assertTrue(spreadSignal != contiguousSignal, "slot width must change the signal");

        ZiskVerifier expectsSpread = new ZiskVerifier(
            IZiskSnarkPlonkVerifier(address(new ExpectSignalPlonkVerifier(spreadSignal)))
        );
        assertTrue(expectsSpread.verify(pis, _ziskSnarkWords()), "digest spread over guest publics");

        ZiskVerifier expectsContiguous = new ZiskVerifier(
            IZiskSnarkPlonkVerifier(address(new ExpectSignalPlonkVerifier(contiguousSignal)))
        );
        assertFalse(expectsContiguous.verify(pis, _ziskSnarkWords()), "contiguous digest");
    }

    /// @dev The two program VK pins have one role each and are not
    ///      interchangeable. A stand-in that expects the swapped-pin signal
    ///      (inner pin on the wire, aggregator pin in the digest) is rejected,
    ///      because the reconstruction puts each pin in its own place.
    function test_swappedProgramVkPins_rejected() public {
        ZiskVerifier swappedExpectation = new ZiskVerifier(
            IZiskSnarkPlonkVerifier(address(new ExpectSignalPlonkVerifier(_swappedPinSignal())))
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
