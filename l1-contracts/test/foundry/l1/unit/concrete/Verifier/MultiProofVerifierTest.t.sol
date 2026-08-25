// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {NonZeroCarriedHash} from "contracts/common/L1ContractErrors.sol";
import {DeployCTML1OrGateway} from "deploy-scripts/ctm/DeployCTML1OrGateway.sol";

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
contract MockExpectPublicInputsVerifier is IVerifier {
    bytes32 public immutable expectedPisHash;

    constructor(uint256[] memory _pis) {
        expectedPisHash = keccak256(abi.encode(_pis));
    }

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external view returns (bool) {
        return keccak256(abi.encode(_publicInputs)) == expectedPisHash;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(6));
    }
}

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

    /// @dev The verifier reads the requirement from its caller, which in
    ///      production is the chain's diamond. The test contract calls it
    ///      directly, so it stands in for that chain.
    bool internal ziskDisabled;

    function ziskVerificationDisabled() external view returns (bool) {
        return ziskDisabled;
    }

    function setUp() public {
        passVerifier = new MockPassVerifier();
        failVerifier = new MockFailVerifier();
        verifier = new MultiProofVerifier(IVerifier(address(passVerifier)), IVerifier(address(passVerifier)));
        // MultiProofTestnetVerifier wraps MultiProofVerifier — adds mock proof support.
        testnetVerifier = new MultiProofTestnetVerifier(IVerifier(address(verifier)));
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
        assertEq(address(verifier.AIRBENDER_VERIFIER()), address(passVerifier));
        assertEq(address(verifier.ZISK_RANGE_VERIFIER()), address(passVerifier));
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

    /// @dev The header word carries the proof type alone: this format holds no
    ///      verifier version, so every bit above the type field is reserved. A
    ///      payload that sets one would otherwise read as a plain type 5.
    function test_headerReservedBitsSet_rejected() public {
        uint256[] memory proof = _type5Proof(0, 2);
        proof[0] = (1 << 8) | 5;

        vm.expectRevert(MultiProofVerifier.InvalidProofFormat.selector);
        verifier.verify(_singlePublicInputs(), proof);
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
        MultiProofVerifier failing = new MultiProofVerifier(
            IVerifier(address(failVerifier)),
            IVerifier(address(passVerifier))
        );

        vm.expectRevert(MultiProofVerifier.AirbenderVerificationFailed.selector);
        failing.verify(_singlePublicInputs(), _type5Proof(0, 2));
    }

    function test_multiProof_ziskFails_reverts() public {
        MultiProofVerifier failing = new MultiProofVerifier(
            IVerifier(address(passVerifier)),
            IVerifier(address(failVerifier))
        );

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        failing.verify(_singlePublicInputs(), _type5Proof(0, 2));
    }

    /// @dev A chain that turns the requirement off settles on the Airbender
    ///      proof alone: a ZiSK verifier that rejects everything is not reached.
    function test_ziskDisabled_settlesOnAirbenderAlone() public {
        MultiProofVerifier lane = new MultiProofVerifier(
            IVerifier(address(passVerifier)),
            IVerifier(address(failVerifier))
        );

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        lane.verify(_rangePublicInputs(), _type5Proof(0, 2));

        ziskDisabled = true;
        assertTrue(lane.verify(_rangePublicInputs(), _type5Proof(0, 2)));
    }

    // --- Forwarding to the sub-verifiers ---

    /// @dev The Airbender side receives the raw batch public inputs. The
    ///      wrapped ZKsync OS verifier owns the fold that the settlement layer
    ///      defines, so this contract hands them over whole.
    function test_airbender_receivesRawBatchInputs() public {
        uint256[] memory pis = _rangePublicInputs();

        MultiProofVerifier expecting = new MultiProofVerifier(
            IVerifier(address(new MockExpectPublicInputsVerifier(pis))),
            IVerifier(address(passVerifier))
        );

        assertTrue(expecting.verify(pis, _type5Proof(0, 2)));
    }

    /// @dev The ZiSK range verifier receives the RAW batch public inputs (so it
    ///      can rebuild the self-contained seed-0 chain itself) and exactly the
    ///      24-word SNARK section — never a pre-chained single value and never
    ///      the ten dropped public-values words.
    /// @dev A carried hash is refused before either side is reached, so the
    ///      proof carries zero in that slot.
    function test_zisk_receivesRawBatchInputsAnd24WordProof() public {
        uint256[] memory pis = _rangePublicInputs();
        MultiProofVerifier expecting = new MultiProofVerifier(
            IVerifier(address(passVerifier)),
            IVerifier(address(new MockExpectZiskCallVerifier(pis)))
        );

        assertTrue(expecting.verify(pis, _type5Proof(0, 2)));
    }

    // --- Sub-verifier seen by the deployment tooling ---

    /// @dev The chain's verifier is a multi-proof wrapper, and the deployment
    ///      and upgrade tooling reads the PLONK sub-verifier off it. Both
    ///      wrappers must answer with the sub-verifier of the one ZKsync OS
    ///      verifier at the end of the wrapping chain, so this drives the real
    ///      tooling helper rather than the getter directly.
    function test_deployTooling_readsSubVerifierThroughWrappers() public {
        address plonk = address(new MockPassVerifier());
        ZKsyncOSVerifier airbenderVerifier = new ZKsyncOSVerifier(IVerifier(plonk));
        MultiProofVerifier multiProof = new MultiProofVerifier(
            IVerifier(address(airbenderVerifier)),
            IVerifier(address(new MockPassVerifier()))
        );
        MultiProofTestnetVerifier testnetWrapper = new MultiProofTestnetVerifier(IVerifier(address(multiProof)));

        (, address readPlonk) = DeployCTML1OrGateway.getSubVerifiers(address(multiProof), true);
        assertEq(readPlonk, plonk, "plonk through MultiProofVerifier");

        (, readPlonk) = DeployCTML1OrGateway.getSubVerifiers(address(testnetWrapper), true);
        assertEq(readPlonk, plonk, "plonk through MultiProofTestnetVerifier");
    }

    /// @dev An Airbender inner verifier that holds no sub-verifier has no answer
    ///      to give, so the read reverts rather than reporting a zero address the
    ///      tooling would treat as an unwired sub-verifier.
    function test_subVerifierRead_revertsWithoutZKsyncOSVerifier() public {
        vm.expectRevert();
        verifier.PLONK_VERIFIER();
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
        proof[3] = uint256(42) >> 32;

        assertTrue(testnetVerifier.verify(_singlePublicInputs(), proof));
    }

    /// @dev The mock route must expect the value the settlement layer defines,
    ///      for one batch and for many. A mock proof built against a second fold
    ///      would pass here and be refused on a real chain.
    function test_testnet_mockProof_expectsTheSettlementLayerFold() public {
        ZKsyncOSVerifier settlementFold = new ZKsyncOSVerifier(IVerifier(address(passVerifier)));

        uint256[][] memory cases = new uint256[][](2);
        cases[0] = _singlePublicInputs();
        cases[1] = _rangePublicInputs();

        for (uint256 i = 0; i < cases.length; ++i) {
            uint256[] memory proof = new uint256[](4);
            proof[0] = 3;
            proof[1] = 0;
            proof[2] = 13;
            proof[3] = settlementFold.computeZKsyncOSHash(0, cases[i]);

            assertTrue(testnetVerifier.verify(cases[i], proof), "mock route rejected the settlement fold");
        }
    }

    /// @dev The carried-hash slot is reserved on the mock route too, so a mock
    ///      proof cannot open a continuation the real route refuses.
    function test_testnet_mockProof_revertsOnCarriedHash() public {
        uint256[] memory proof = new uint256[](4);
        proof[0] = 3;
        proof[1] = 1;
        proof[2] = 13;
        proof[3] = uint256(42) >> 32;

        vm.expectRevert(NonZeroCarriedHash.selector);
        testnetVerifier.verify(_singlePublicInputs(), proof);
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
