// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IZiskVerifier} from "contracts/state-transition/chain-interfaces/IZiskVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";

/// @dev Mock verifier that always returns true.
contract MockPassVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }
    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev Mock verifier that always returns false.
contract MockFailVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return false;
    }
    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(2));
    }
}

/// @dev Mock ZiSK verifier: always passes and exposes configurable wire-form
///      VK pins, like the generated ZiskVerifier does.
contract MockZiskVerifier is IZiskVerifier {
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

/// @dev Mock verifier that passes only when called with the expected
///      single-element public-inputs array.
contract MockExpectArgsVerifier is IVerifier {
    uint256 public immutable expectedArg;

    constructor(uint256 _expectedArg) {
        expectedArg = _expectedArg;
    }

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external view returns (bool) {
        return _publicInputs.length == 1 && _publicInputs[0] == expectedArg;
    }
    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(4));
    }
}

contract MultiProofVerifierTest is Test {
    /// @dev Arbitrary wire-form pins for the mock per-batch ZiSK verifier.
    bytes32 internal constant INNER_PROGRAM_VK = bytes32(uint256(0x1111));
    bytes32 internal constant ROOT_C_VADCOP_FINAL = bytes32(uint256(0x2222));

    MultiProofVerifier verifier;
    MultiProofTestnetVerifier testnetVerifier;
    MockPassVerifier passVerifier;
    MockFailVerifier failVerifier;
    MockZiskVerifier ziskPinsVerifier;

    function setUp() public {
        passVerifier = new MockPassVerifier();
        failVerifier = new MockFailVerifier();
        ziskPinsVerifier = new MockZiskVerifier(INNER_PROGRAM_VK, ROOT_C_VADCOP_FINAL);
        verifier = new MultiProofVerifier(
            IVerifier(address(passVerifier)),
            IVerifier(address(ziskPinsVerifier)),
            address(this)
        );
        verifier.setZiskRangeVerifier(IVerifier(address(passVerifier)));
        // MultiProofTestnetVerifier wraps MultiProofVerifier — adds mock proof support.
        testnetVerifier = new MultiProofTestnetVerifier(IVerifier(address(verifier)));
    }

    /// @dev Replay of MultiProofVerifier._computeZKsyncOSHash.
    function _chainedPI(uint256 _seed, uint256[] memory _pis) internal pure returns (uint256 result) {
        result = _seed;
        uint256 i = 0;
        if (result == 0) {
            result = _pis[0];
            i = 1;
        }
        for (; i < _pis.length; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _pis[i]))) >> 32;
        }
    }

    /// @dev The binding digest an aggregated range proof must commit to:
    ///      the chain is ALWAYS self-contained (seed 0).
    function _rangeDigest(uint256[] memory _pis) internal pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(INNER_PROGRAM_VK, ROOT_C_VADCOP_FINAL, bytes32(_chainedPI(0, _pis)))
                )
            );
    }

    /// @dev A 3-batch public-inputs array.
    function _rangePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](3);
        pis[0] = 42;
        pis[1] = 43;
        pis[2] = 44;
    }

    /// @dev Build a type-5 proof whose ZiSK public-values word 1 is `digest`.
    function _rangeProof(uint256 _previousHash, uint256 _digest) internal pure returns (uint256[] memory proof) {
        uint256 airbenderLen = 2;
        proof = new uint256[](3 + airbenderLen + 34);
        proof[0] = 5;
        proof[1] = _previousHash;
        proof[2] = airbenderLen;
        proof[3] = 111;
        proof[4] = 222;
        proof[5 + 25] = _digest;
    }

    // --- MultiProofVerifier (prod) tests ---

    function test_deployment() public view {
        assertEq(address(verifier.airbenderVerifier()), address(passVerifier));
        assertEq(address(verifier.ziskVerifier()), address(ziskPinsVerifier));
        assertEq(address(verifier.ziskRangeVerifier()), address(passVerifier));
    }

    function test_mockProof_rejected_in_prod() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](4);
        proof[0] = 3;
        proof[1] = 0;
        proof[2] = 13;
        proof[3] = 42;

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 3));
        verifier.verify(publicInputs, proof);
    }

    function test_multiProof_bothPass() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256 airbenderLen = 2;
        uint256 ziskLen = 34;
        uint256[] memory proof = new uint256[](3 + airbenderLen + ziskLen);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = airbenderLen;
        proof[3] = 111;
        proof[4] = 222;
        for (uint256 i = 0; i < ziskLen; i++) {
            proof[5 + i] = i;
        }
        // Guest-publics word 1 carries the full batch commitment; the public
        // input equals it truncated by 32 bits.
        proof[5 + 25] = 42 << 32;

        assertTrue(verifier.verify(publicInputs, proof));
    }

    function test_multiProof_commitmentMismatch_reverts() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](3 + 2 + 34);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = 2;
        // ZiSK public values commit to a DIFFERENT batch than the public input.
        proof[5 + 25] = 43 << 32;

        vm.expectRevert(
            abi.encodeWithSelector(MultiProofVerifier.ZiskCommitmentMismatch.selector, 42, 43)
        );
        verifier.verify(publicInputs, proof);
    }

    function test_multiProof_airbenderFails_reverts() public {
        verifier.setAirbenderVerifier(IVerifier(address(failVerifier)));

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](3 + 2 + 34);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = 2;

        vm.expectRevert(MultiProofVerifier.AirbenderVerificationFailed.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_multiProof_ziskFails_reverts() public {
        // A single batch now verifies through the aggregation verifier, so a
        // failing range verifier makes the ZiSK check fail.
        verifier.setZiskRangeVerifier(IVerifier(address(failVerifier)));

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](3 + 2 + 34);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = 2;
        proof[5 + 25] = 42 << 32;

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_singleProofType2_rejected() public {
        uint256[] memory publicInputs = new uint256[](1);
        uint256[] memory proof = new uint256[](44);
        proof[0] = 2;

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 2));
        verifier.verify(publicInputs, proof);
    }

    function test_setVerifiers_onlyOwner() public {
        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        verifier.setAirbenderVerifier(IVerifier(address(failVerifier)));

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        verifier.setZiskRangeVerifier(IVerifier(address(failVerifier)));
    }

    // --- Range (N > 1 batches, aggregated ZiSK proof) tests ---

    function test_rangeProof_digestBinding_passes() public view {
        uint256[] memory pis = _rangePublicInputs();
        uint256[] memory proof = _rangeProof(0, _rangeDigest(pis));

        assertTrue(verifier.verify(pis, proof));
    }

    /// @dev The decided seed semantics: the aggregated ZiSK digest chain is
    ///      SELF-CONTAINED (seed 0) even when the Airbender public input
    ///      continues a nonzero previous_hash.
    function test_rangeProof_selfContainedSeed_previousHashDoesNotEnterDigest() public {
        uint256[] memory pis = _rangePublicInputs();
        uint256 previousHash = uint256(keccak256("previous batch chain")) >> 32;

        // The Airbender side must still see the previous_hash-seeded chain...
        verifier.setAirbenderVerifier(
            IVerifier(address(new MockExpectArgsVerifier(_chainedPI(previousHash, pis))))
        );

        // ...while the ZiSK digest binds the seed-0 chain.
        uint256[] memory proof = _rangeProof(previousHash, _rangeDigest(pis));
        assertTrue(verifier.verify(pis, proof));

        // A digest built from the previous_hash-seeded chain is rejected.
        uint256 wrongDigest = uint256(
            keccak256(
                abi.encodePacked(
                    INNER_PROGRAM_VK,
                    ROOT_C_VADCOP_FINAL,
                    bytes32(_chainedPI(previousHash, pis))
                )
            )
        );
        uint256[] memory wrongProof = _rangeProof(previousHash, wrongDigest);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiProofVerifier.ZiskRangeDigestMismatch.selector,
                _rangeDigest(pis),
                wrongDigest
            )
        );
        verifier.verify(pis, wrongProof);
    }

    function test_rangeProof_digestMismatch_reverts() public {
        uint256[] memory pis = _rangePublicInputs();
        uint256 digest = _rangeDigest(pis);
        uint256[] memory proof = _rangeProof(0, digest ^ 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiProofVerifier.ZiskRangeDigestMismatch.selector,
                digest,
                digest ^ 1
            )
        );
        verifier.verify(pis, proof);
    }

    /// @dev The digest binds the inner programVK and rootCVadcopFinal wire
    ///      forms: a digest over the right chain but the wrong pins fails.
    function test_rangeProof_wrongInnerPins_reverts() public {
        uint256[] memory pis = _rangePublicInputs();
        uint256 wrongDigest = uint256(
            keccak256(
                abi.encodePacked(
                    INNER_PROGRAM_VK ^ bytes32(uint256(1)),
                    ROOT_C_VADCOP_FINAL,
                    bytes32(_chainedPI(0, pis))
                )
            )
        );
        uint256[] memory proof = _rangeProof(0, wrongDigest);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiProofVerifier.ZiskRangeDigestMismatch.selector,
                _rangeDigest(pis),
                wrongDigest
            )
        );
        verifier.verify(pis, proof);
    }

    function test_rangeProof_rangeVerifierUnset_reverts() public {
        MultiProofVerifier bare = new MultiProofVerifier(
            IVerifier(address(passVerifier)),
            IVerifier(address(ziskPinsVerifier)),
            address(this)
        );

        uint256[] memory pis = _rangePublicInputs();
        uint256[] memory proof = _rangeProof(0, _rangeDigest(pis));

        vm.expectRevert(MultiProofVerifier.ZiskRangeVerifierNotSet.selector);
        bare.verify(pis, proof);

        // A single batch now also needs the aggregation verifier: every range
        // verifies through it.
        uint256[] memory singleInput = new uint256[](1);
        singleInput[0] = 42;
        uint256[] memory singleProof = _rangeProof(0, 42 << 32);
        vm.expectRevert(MultiProofVerifier.ZiskRangeVerifierNotSet.selector);
        bare.verify(singleInput, singleProof);
    }

    /// @dev The single-batch path verifies through the aggregation verifier,
    ///      not the inner-pin source. A failing inner verifier does not stop a
    ///      valid single-batch proof; a failing range verifier does (see
    ///      test_multiProof_ziskFails_reverts).
    function test_singleBatch_usesRangeVerifierNotInner() public {
        // The inner-pin source fails; the aggregation verifier passes.
        verifier.setZiskVerifier(IVerifier(address(failVerifier)));

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;
        uint256[] memory proof = _rangeProof(0, 42 << 32);

        assertTrue(verifier.verify(publicInputs, proof));
    }

    function test_rangeProof_rangeVerifierFails_reverts() public {
        verifier.setZiskRangeVerifier(IVerifier(address(failVerifier)));

        uint256[] memory pis = _rangePublicInputs();
        uint256[] memory proof = _rangeProof(0, _rangeDigest(pis));

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        verifier.verify(pis, proof);
    }

    /// @dev Range mode never takes the single-batch path: an aggregated
    ///      digest can not be passed off as a batch commitment or vice versa.
    function test_rangeProof_singleBatchCommitment_rejectedInRangeMode() public {
        uint256[] memory pis = _rangePublicInputs();
        // A "commitment-style" word (chained PI << 32) is not the digest.
        uint256 commitmentStyle = _chainedPI(0, pis) << 32;
        uint256[] memory proof = _rangeProof(0, commitmentStyle);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiProofVerifier.ZiskRangeDigestMismatch.selector,
                _rangeDigest(pis),
                commitmentStyle
            )
        );
        verifier.verify(pis, proof);
    }

    // --- MultiProofTestnetVerifier(MultiProofVerifier) composition tests ---

    function test_testnet_emptyProof_accepted() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;
        uint256[] memory proof = new uint256[](0);

        assertTrue(testnetVerifier.verify(publicInputs, proof));
    }

    function test_testnet_mockProof_passes() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](4);
        proof[0] = 3;
        proof[1] = 0;
        proof[2] = 13;
        proof[3] = 42;

        assertTrue(testnetVerifier.verify(publicInputs, proof));
    }

    function test_testnet_multiProof_delegated() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256 airbenderLen = 2;
        uint256 ziskLen = 34;
        uint256[] memory proof = new uint256[](3 + airbenderLen + ziskLen);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = airbenderLen;
        proof[3] = 111;
        proof[4] = 222;
        for (uint256 i = 0; i < ziskLen; i++) {
            proof[5 + i] = i;
        }
        proof[5 + 25] = 42 << 32;

        assertTrue(testnetVerifier.verify(publicInputs, proof));
    }

    function test_testnet_singleProofType2_rejected() public {
        uint256[] memory publicInputs = new uint256[](1);
        uint256[] memory proof = new uint256[](44);
        proof[0] = 2;

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 2));
        testnetVerifier.verify(publicInputs, proof);
    }
}
