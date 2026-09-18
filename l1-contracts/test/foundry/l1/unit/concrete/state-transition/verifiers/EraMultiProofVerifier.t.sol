// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    AIRBENDER_PROOF_SYSTEM_MASK,
    AIRBENDER_SNARK_PROOF_LENGTH,
    BOOJUM_FFLONK_PROOF_LENGTH,
    BOOJUM_PROOF_SYSTEM_MASK,
    ERA_MULTI_PROOF_TYPE
} from "contracts/common/Config.sol";
import {
    AirbenderVerificationFailed,
    BoojumVerificationFailed,
    InvalidDisabledProofSystemsMask,
    InvalidProofFormat,
    InvalidPublicInputsLength,
    UnknownVerifierType
} from "contracts/common/L1ContractErrors.sol";
import {ChainStub, RevealingVerifier, StubVerifier} from "./VerifierStubs.sol";

contract EraMultiProofVerifierTest is Test {
    uint256 internal constant BOOJUM_PUBLIC_INPUT = uint256(keccak256("boojum-transition-hash"));
    uint256 internal constant AIRBENDER_PUBLIC_INPUT = uint256(keccak256("airbender-transition-hash"));
    uint256 internal constant PROOF_LENGTH = 1 + BOOJUM_FFLONK_PROOF_LENGTH + AIRBENDER_SNARK_PROOF_LENGTH;
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

    /// `[type, boojum(24 words), airbender(44 words)]`, with distinct words per segment.
    function _proof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        for (uint256 i = 0; i < BOOJUM_FFLONK_PROOF_LENGTH; ++i) {
            proof[1 + i] = 0xb0 + i;
        }
        for (uint256 i = 0; i < AIRBENDER_SNARK_PROOF_LENGTH; ++i) {
            proof[1 + BOOJUM_FFLONK_PROOF_LENGTH + i] = 0xa0 + i;
        }
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
        assertTrue(chain.callVerify(verifier, _publicInputs(), _proof()));
    }

    function test_revertsWhenBoojumRejects() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(rejecting)));
        vm.expectRevert(BoojumVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _proof());
    }

    function test_revertsWhenAirbenderRejects() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(rejecting)));
        vm.expectRevert(AirbenderVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _proof());
    }

    function test_passesFirstPublicInputAndBoojumSegmentToBoojum() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(new RevealingVerifier())));
        vm.expectRevert(
            abi.encodeWithSelector(
                RevealingVerifier.Revealed.selector,
                BOOJUM_PUBLIC_INPUT,
                1,
                0xb0,
                BOOJUM_FFLONK_PROOF_LENGTH
            )
        );
        chain.callVerify(v, _publicInputs(), _proof());
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
        chain.callVerify(v, _publicInputs(), _proof());
    }

    /// A garbage Boojum segment is refused by the real FFLONK verifier.
    function test_realBoojumVerifierRejectsGarbage() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(new EraVerifierFflonk())));
        vm.expectRevert();
        chain.callVerify(v, _publicInputs(), _proof());
    }

    // ============ Disabled proof systems ============

    function test_skipsAirbenderWhenChainDisabledIt() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(rejecting)));
        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(v, _publicInputs(), _proof()));
    }

    function test_skipsBoojumWhenChainDisabledIt() public {
        EraMultiProofVerifier v = _withBoojum(IVerifier(address(rejecting)));
        chain.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(v, _publicInputs(), _proof()));
    }

    function test_revertsWhenChainDisabledEverything() public {
        chain.setDisabledProofSystems(BOTH);
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, BOTH));
        chain.callVerify(verifier, _publicInputs(), _proof());
    }

    /// The mask is read from `msg.sender` on every call.
    function test_maskIsReadPerCallingChain() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(rejecting)));
        ChainStub airbenderDisabled = new ChainStub();
        airbenderDisabled.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        vm.expectRevert(AirbenderVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _proof());
        assertTrue(airbenderDisabled.callVerify(v, _publicInputs(), _proof()));
    }

    /// A CTM deployed without an Airbender verifier requires Boojum only, and Boojum cannot then be disabled.
    function test_unwiredVerifierIsNotRequired() public {
        EraMultiProofVerifier v = _withAirbender(IVerifier(address(0)));
        assertEq(v.supportedProofSystems(), BOOJUM_PROOF_SYSTEM_MASK);
        assertEq(v.requiredProofSystems(0), BOOJUM_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(v, _publicInputs(), _proof()));

        chain.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_MASK);
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, BOOJUM_PROOF_SYSTEM_MASK));
        chain.callVerify(v, _publicInputs(), _proof());
    }

    // ============ Envelope ============

    /// Two public inputs regardless of the mask.
    function test_revertsOnWrongPublicInputCount() public {
        uint256[] memory one = new uint256[](1);
        one[0] = BOOJUM_PUBLIC_INPUT;
        vm.expectRevert(InvalidPublicInputsLength.selector);
        chain.callVerify(verifier, one, _proof());

        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        vm.expectRevert(InvalidPublicInputsLength.selector);
        chain.callVerify(verifier, one, _proof());
        chain.setDisabledProofSystems(0);

        uint256[] memory three = new uint256[](3);
        vm.expectRevert(InvalidPublicInputsLength.selector);
        chain.callVerify(verifier, three, _proof());
    }

    function test_revertsOnUnknownProofType() public {
        uint256[] memory proof = _proof();
        proof[0] = ERA_MULTI_PROOF_TYPE + 1;
        vm.expectRevert(UnknownVerifierType.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    /// The envelope is fixed-size; anything else is refused, including an empty proof.
    function test_revertsOnWrongProofLength() public {
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), new uint256[](0));

        uint256[] memory tooShort = new uint256[](PROOF_LENGTH - 1);
        tooShort[0] = ERA_MULTI_PROOF_TYPE;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), tooShort);

        uint256[] memory tooLong = new uint256[](PROOF_LENGTH + 1);
        tooLong[0] = ERA_MULTI_PROOF_TYPE;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), tooLong);
    }

    // ============ Discovery ============

    function test_reportsPolicy() public view {
        assertEq(verifier.supportedProofSystems(), BOTH);
        assertEq(verifier.requiredProofSystems(0), BOTH);
        assertEq(verifier.requiredProofSystems(AIRBENDER_PROOF_SYSTEM_MASK), BOOJUM_PROOF_SYSTEM_MASK);
        assertEq(verifier.requiredProofSystems(BOOJUM_PROOF_SYSTEM_MASK), AIRBENDER_PROOF_SYSTEM_MASK);
        assertEq(verifier.acceptedProofType(), ERA_MULTI_PROOF_TYPE);
        assertFalse(verifier.IS_TESTNET_VERIFIER());
    }

    function test_requiredSystemsRejectsTheAllDisabledMask() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, BOTH));
        verifier.requiredProofSystems(BOTH);
    }

    /// `verificationKeyHash(type)`: 0 Boojum, 2 Airbender; the retired PLONK type 1 is refused.
    function test_reportsKeysByType() public {
        assertEq(verifier.verificationKeyHash(), keccak256("boojum-key"));
        assertEq(verifier.verificationKeyHash(0), keccak256("boojum-key"));
        assertEq(verifier.verificationKeyHash(2), keccak256("airbender-key"));

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(1);
    }
}
