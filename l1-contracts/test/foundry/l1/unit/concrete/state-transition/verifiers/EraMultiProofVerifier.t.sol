// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    AIRBENDER_PROOF_SYSTEM_MASK,
    AIRBENDER_SNARK_PROOF_LENGTH,
    BOOJUM_PROOF_SYSTEM_MASK,
    ERA_MULTI_PROOF_TYPE
} from "contracts/common/Config.sol";
import {
    AirbenderVerificationFailed,
    BoojumVerificationFailed,
    EmptyProofLength,
    InvalidDisabledProofSystemsMask,
    InvalidProofFormat,
    InvalidPublicInputsLength,
    UnknownVerifierType
} from "contracts/common/L1ContractErrors.sol";
import {ChainStub, RevealingVerifier, StubVerifier} from "./VerifierStubs.sol";

contract EraMultiProofVerifierTest is Test {
    uint256 internal constant BOOJUM_PUBLIC_INPUT = uint256(keccak256("boojum-transition-hash"));
    uint256 internal constant AIRBENDER_PUBLIC_INPUT = uint256(keccak256("airbender-transition-hash"));
    uint256 internal constant BOOJUM_SEGMENT_LENGTH = 3;
    uint8 internal constant BOTH = BOOJUM_PROOF_SYSTEM_MASK | AIRBENDER_PROOF_SYSTEM_MASK;

    StubVerifier internal boojum;
    StubVerifier internal airbender;
    StubVerifier internal rejecting;
    EraMultiProofVerifier internal verifier;
    ChainStub internal chain;

    function setUp() public {
        boojum = new StubVerifier(true, keccak256("boojum-key"));
        airbender = new StubVerifier(true, keccak256("airbender-key"));
        rejecting = new StubVerifier(false, bytes32(0));
        verifier = new EraMultiProofVerifier(IVerifier(address(boojum)), IVerifier(address(airbender)));
        chain = new ChainStub();
    }

    function _publicInputs() internal pure returns (uint256[] memory pi) {
        pi = new uint256[](2);
        pi[0] = BOOJUM_PUBLIC_INPUT;
        pi[1] = AIRBENDER_PUBLIC_INPUT;
    }

    /// `[type, N, boojum(N words), airbender(44 words)]`
    function _proof(uint256 _boojumType, uint256 _boojumLength) internal pure returns (uint256[] memory proof) {
        proof = new uint256[](2 + _boojumLength + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = _boojumLength;
        if (_boojumLength > 0) {
            proof[2] = _boojumType;
        }
        for (uint256 i = 0; i < AIRBENDER_SNARK_PROOF_LENGTH; ++i) {
            proof[2 + _boojumLength + i] = 0xa0 + i;
        }
    }

    function _default() internal pure returns (uint256[] memory) {
        return _proof(1, BOOJUM_SEGMENT_LENGTH);
    }

    function _withAirbender(IVerifier _airbender) internal returns (EraMultiProofVerifier) {
        return new EraMultiProofVerifier(IVerifier(address(boojum)), _airbender);
    }

    function _withBoojum(IVerifier _boojum) internal returns (EraMultiProofVerifier) {
        return new EraMultiProofVerifier(_boojum, IVerifier(address(airbender)));
    }

    // ============ Verification ============

    function test_constructor_setsVerifiers() public view {
        assertEq(address(verifier.BOOJUM_VERIFIER()), address(boojum));
        assertEq(address(verifier.AIRBENDER_VERIFIER()), address(airbender));
    }

    function test_acceptsWhenBothAccept() public view {
        assertTrue(chain.callVerify(verifier, _publicInputs(), _default()));
    }

    function test_revertsWhenBoojumRejects() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(rejecting)));
        vm.expectRevert(BoojumVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _default());
    }

    function test_revertsWhenAirbenderRejects() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(rejecting)));
        vm.expectRevert(AirbenderVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _default());
    }

    function test_passesFirstPublicInputAndBoojumSegmentToBoojum() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(new RevealingVerifier())));
        vm.expectRevert(
            abi.encodeWithSelector(
                RevealingVerifier.Revealed.selector,
                BOOJUM_PUBLIC_INPUT,
                1,
                1,
                BOOJUM_SEGMENT_LENGTH
            )
        );
        chain.callVerify(v, _publicInputs(), _default());
    }

    function test_passesSecondPublicInputAndAirbenderSegmentToAirbender() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(new RevealingVerifier())));
        vm.expectRevert(
            abi.encodeWithSelector(
                RevealingVerifier.Revealed.selector,
                AIRBENDER_PUBLIC_INPUT,
                1,
                0xa0,
                AIRBENDER_SNARK_PROOF_LENGTH
            )
        );
        chain.callVerify(v, _publicInputs(), _default());
    }

    // ============ Disabled proof systems ============

    function test_skipsAirbenderWhenChainDisabledIt() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(rejecting)));
        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(v, _publicInputs(), _default()));
    }

    function test_skipsBoojumWhenChainDisabledIt() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(rejecting)));
        chain.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(v, _publicInputs(), _proof(1, 0)));
    }

    function test_revertsWhenChainDisabledEverything() public {
        chain.setDisabledProofSystems(BOTH);
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, BOTH));
        chain.callVerify(verifier, _publicInputs(), _default());
    }

    /// The mask is read from `msg.sender` on every call.
    function test_maskIsReadPerCallingChain() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(rejecting)));
        ChainStub airbenderDisabled = new ChainStub();
        airbenderDisabled.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        vm.expectRevert(AirbenderVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _default());
        assertTrue(airbenderDisabled.callVerify(v, _publicInputs(), _default()));
    }

    /// A CTM deployed without an Airbender verifier requires Boojum only, and Boojum cannot then be disabled.
    function test_unwiredVerifierIsNotRequired() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(0)));
        assertEq(v.supportedProofSystems(), BOOJUM_PROOF_SYSTEM_MASK);
        assertEq(v.requiredProofSystems(0), BOOJUM_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(v, _publicInputs(), _default()));

        chain.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_MASK);
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, BOOJUM_PROOF_SYSTEM_MASK));
        chain.callVerify(v, _publicInputs(), _default());
    }

    // ============ Envelope ============

    /// Two public inputs regardless of the mask.
    function test_revertsOnWrongPublicInputCount() public {
        uint256[] memory one = new uint256[](1);
        one[0] = BOOJUM_PUBLIC_INPUT;
        vm.expectRevert(InvalidPublicInputsLength.selector);
        chain.callVerify(verifier, one, _default());

        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        vm.expectRevert(InvalidPublicInputsLength.selector);
        chain.callVerify(verifier, one, _default());
        chain.setDisabledProofSystems(0);

        uint256[] memory three = new uint256[](3);
        vm.expectRevert(InvalidPublicInputsLength.selector);
        chain.callVerify(verifier, three, _default());
    }

    function test_revertsOnEmptyProof() public {
        vm.expectRevert(EmptyProofLength.selector);
        chain.callVerify(verifier, _publicInputs(), new uint256[](0));
    }

    function test_revertsOnUnknownProofType() public {
        uint256[] memory proof = _default();
        proof[0] = ERA_MULTI_PROOF_TYPE + 1;
        vm.expectRevert(UnknownVerifierType.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    function test_revertsOnWrongEnvelopeLength() public {
        uint256[] memory proof = _default();
        uint256[] memory tooLong = new uint256[](proof.length + 1);
        for (uint256 i = 0; i < proof.length; ++i) {
            tooLong[i] = proof[i];
        }
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), tooLong);

        uint256[] memory tooShort = new uint256[](2 + AIRBENDER_SNARK_PROOF_LENGTH - 1);
        tooShort[0] = ERA_MULTI_PROOF_TYPE;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), tooShort);

        uint256[] memory headerOnly = new uint256[](1);
        headerOnly[0] = ERA_MULTI_PROOF_TYPE;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), headerOnly);
    }

    /// A declared Boojum length that would overflow `2 + N + 44` is an envelope error, not an arithmetic panic.
    function test_revertsOnOutOfRangeBoojumLength() public {
        uint256[] memory proof = _default();
        proof[1] = type(uint256).max;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    /// Uses the real `EraDualVerifier`: an Airbender-typed proof is not routable through the Boojum segment,
    /// and an empty Boojum segment is refused while Boojum is required.
    function test_boojumSegmentGoesThroughTheRealRouter() public {
        EraDualVerifier router = new EraDualVerifier(IVerifierV2(address(boojum)), IVerifier(address(boojum)));
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(router)));

        vm.expectRevert(UnknownVerifierType.selector);
        chain.callVerify(v, _publicInputs(), _proof(2, BOOJUM_SEGMENT_LENGTH));

        vm.expectRevert(EmptyProofLength.selector);
        chain.callVerify(v, _publicInputs(), _proof(1, 0));
    }

    // ============ Discovery ============

    function test_reportsPolicy() public view {
        assertEq(verifier.supportedProofSystems(), BOTH);
        assertEq(verifier.requiredProofSystems(0), BOTH);
        assertEq(verifier.requiredProofSystems(AIRBENDER_PROOF_SYSTEM_MASK), BOOJUM_PROOF_SYSTEM_MASK);
        assertEq(verifier.requiredProofSystems(BOOJUM_PROOF_SYSTEM_MASK), AIRBENDER_PROOF_SYSTEM_MASK);
        assertEq(verifier.acceptedProofType(), ERA_MULTI_PROOF_TYPE);
    }

    function test_requiredSystemsRejectsTheAllDisabledMask() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, BOTH));
        verifier.requiredProofSystems(BOTH);
    }

    /// `verificationKeyHash(type)`: 0 and 1 from the Boojum router, 2 from Airbender.
    function test_reportsKeysByType() public {
        StubVerifier fflonk = new StubVerifier(true, keccak256("fflonk-key"));
        StubVerifier plonk = new StubVerifier(true, keccak256("plonk-key"));
        EraDualVerifier router = new EraDualVerifier(IVerifierV2(address(fflonk)), IVerifier(address(plonk)));
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(router)));

        assertEq(v.verificationKeyHash(), router.verificationKeyHash());
        assertEq(v.verificationKeyHash(0), keccak256("fflonk-key"));
        assertEq(v.verificationKeyHash(1), keccak256("plonk-key"));
        assertEq(v.verificationKeyHash(2), keccak256("airbender-key"));
        assertEq(address(v.FFLONK_VERIFIER()), address(fflonk));
        assertEq(address(v.PLONK_VERIFIER()), address(plonk));
    }
}
