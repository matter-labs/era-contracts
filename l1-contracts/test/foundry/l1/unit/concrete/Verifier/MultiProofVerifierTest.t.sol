// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
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

/// @dev Mock verifier that passes only when called with the expected
///      single-element public-inputs array. Used to assert the Airbender side
///      receives the previous_hash-seeded chain.
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

/// @dev Mock range verifier that passes only when it receives the RAW batch
///      public inputs (not a pre-chained single value) and exactly a 24-word
///      SNARK proof — i.e. exactly what the reconstructing range verifier
///      needs to rebuild the ZiSK public values itself.
contract MockExpectZiskCallVerifier is IVerifier {
    bytes32 public immutable expectedPisHash;

    constructor(uint256[] memory _pis) {
        expectedPisHash = keccak256(abi.encode(_pis));
    }

    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external view returns (bool) {
        return _proof.length == 24 && keccak256(abi.encode(_publicInputs)) == expectedPisHash;
    }
    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(5));
    }
}

/// @notice Flow tests for MultiProofVerifier: the type-5 decode, the split of
///         Airbender vs ZiSK sections, the forwarding of inputs, and the revert
///         conditions. The ZiSK SNARK crypto (public-values reconstruction and
///         the pairing) is exercised against real vectors/fixtures in
///         MultiProofRangeVectorTest and ZiskVerifierRealProofTest; here the
///         range verifier is mocked.
contract MultiProofVerifierTest is Test {
    MultiProofVerifier verifier;
    MultiProofTestnetVerifier testnetVerifier;
    MockPassVerifier passVerifier;
    MockFailVerifier failVerifier;

    function setUp() public {
        passVerifier = new MockPassVerifier();
        failVerifier = new MockFailVerifier();
        verifier = new MultiProofVerifier(IVerifier(address(passVerifier)), address(this));
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

    /// @dev A single-batch public-inputs array.
    function _singlePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](1);
        pis[0] = 42;
    }

    /// @dev A 3-batch public-inputs array.
    function _rangePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](3);
        pis[0] = 42;
        pis[1] = 43;
        pis[2] = 44;
    }

    /// @dev Build a type-5 proof: [type|version, prevHash, N, airbender[N], zisk[24]].
    ///      The 24-word ZiSK section is opaque here (the mock range verifier
    ///      reconstructs the public values it needs from the batch inputs).
    function _type5Proof(uint256 _previousHash, uint256 _airbenderLen) internal pure returns (uint256[] memory proof) {
        proof = new uint256[](3 + _airbenderLen + 24);
        proof[0] = 5; // MULTI_PROOF_TYPE
        proof[1] = _previousHash;
        proof[2] = _airbenderLen;
        for (uint256 i = 0; i < _airbenderLen; i++) {
            proof[3 + i] = 100 + i;
        }
        uint256 ziskStart = 3 + _airbenderLen;
        for (uint256 i = 0; i < 24; i++) {
            proof[ziskStart + i] = 1000 + i;
        }
    }

    // --- Deployment / config ---

    function test_deployment() public view {
        assertEq(address(verifier.airbenderVerifier()), address(passVerifier));
        assertEq(address(verifier.ziskRangeVerifier()), address(passVerifier));
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

    // --- Proof-type gating ---

    function test_mockProof_rejected_in_prod() public {
        uint256[] memory publicInputs = _singlePublicInputs();

        uint256[] memory proof = new uint256[](4);
        proof[0] = 3;
        proof[1] = 0;
        proof[2] = 13;
        proof[3] = 42;

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 3));
        verifier.verify(publicInputs, proof);
    }

    function test_singleProofType2_rejected() public {
        uint256[] memory publicInputs = _singlePublicInputs();
        uint256[] memory proof = new uint256[](30);
        proof[0] = 2;

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 2));
        verifier.verify(publicInputs, proof);
    }

    function test_proofTooShort_reverts() public {
        uint256[] memory publicInputs = _singlePublicInputs();
        // Declares 2 Airbender words but does not carry the 24 ZiSK words.
        uint256[] memory proof = new uint256[](3 + 2 + 10);
        proof[0] = 5;
        proof[2] = 2;

        vm.expectRevert(MultiProofVerifier.ProofTooShort.selector);
        verifier.verify(publicInputs, proof);
    }

    // --- Happy path / sub-verifier outcomes ---

    function test_multiProof_bothPass() public view {
        assertTrue(verifier.verify(_singlePublicInputs(), _type5Proof(0, 2)));
        assertTrue(verifier.verify(_rangePublicInputs(), _type5Proof(0, 2)));
    }

    function test_multiProof_airbenderFails_reverts() public {
        verifier.setAirbenderVerifier(IVerifier(address(failVerifier)));

        vm.expectRevert(MultiProofVerifier.AirbenderVerificationFailed.selector);
        verifier.verify(_singlePublicInputs(), _type5Proof(0, 2));
    }

    function test_multiProof_ziskFails_reverts() public {
        verifier.setZiskRangeVerifier(IVerifier(address(failVerifier)));

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        verifier.verify(_singlePublicInputs(), _type5Proof(0, 2));
    }

    function test_rangeVerifierUnset_reverts() public {
        MultiProofVerifier bare = new MultiProofVerifier(IVerifier(address(passVerifier)), address(this));

        // Every range, single batch or many, needs the range verifier set.
        vm.expectRevert(MultiProofVerifier.ZiskRangeVerifierNotSet.selector);
        bare.verify(_singlePublicInputs(), _type5Proof(0, 2));

        vm.expectRevert(MultiProofVerifier.ZiskRangeVerifierNotSet.selector);
        bare.verify(_rangePublicInputs(), _type5Proof(0, 2));
    }

    // --- Forwarding to the sub-verifiers ---

    /// @dev The Airbender side receives the previous_hash-seeded chain over the
    ///      batch public inputs.
    function test_airbender_receivesSeededChain() public {
        uint256[] memory pis = _rangePublicInputs();
        uint256 previousHash = uint256(keccak256("previous batch chain")) >> 32;

        verifier.setAirbenderVerifier(IVerifier(address(new MockExpectArgsVerifier(_chainedPI(previousHash, pis)))));

        assertTrue(verifier.verify(pis, _type5Proof(previousHash, 2)));
    }

    /// @dev The ZiSK range verifier receives the RAW batch public inputs (so it
    ///      can rebuild the self-contained seed-0 chain itself) and exactly the
    ///      24-word SNARK section — never a pre-chained single value and never
    ///      the ten dropped public-values words.
    function test_zisk_receivesRawBatchInputsAnd24WordProof() public {
        uint256[] memory pis = _rangePublicInputs();
        verifier.setZiskRangeVerifier(IVerifier(address(new MockExpectZiskCallVerifier(pis))));

        // A nonzero previous_hash must NOT reach the ZiSK side: it gets the raw
        // batch inputs, unchanged by the Airbender continuation.
        assertTrue(verifier.verify(pis, _type5Proof(uint256(keccak256("prev")) >> 32, 2)));
    }

    // --- MultiProofTestnetVerifier(MultiProofVerifier) composition ---

    function test_testnet_emptyProof_accepted() public view {
        uint256[] memory proof = new uint256[](0);
        assertTrue(testnetVerifier.verify(_singlePublicInputs(), proof));
    }

    function test_testnet_mockProof_passes() public view {
        uint256[] memory proof = new uint256[](4);
        proof[0] = 3;
        proof[1] = 0;
        proof[2] = 13;
        proof[3] = 42;

        assertTrue(testnetVerifier.verify(_singlePublicInputs(), proof));
    }

    function test_testnet_multiProof_delegated() public view {
        assertTrue(testnetVerifier.verify(_singlePublicInputs(), _type5Proof(0, 2)));
    }

    function test_testnet_singleProofType2_rejected() public {
        uint256[] memory proof = new uint256[](30);
        proof[0] = 2;

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 2));
        testnetVerifier.verify(_singlePublicInputs(), proof);
    }
}
