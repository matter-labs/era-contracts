// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    AIRBENDER_PROOF_SYSTEM_DISABLED,
    AIRBENDER_SNARK_PROOF_LENGTH,
    BOOJUM_PROOF_SYSTEM_DISABLED,
    ERA_MULTI_PROOF_TYPE
} from "contracts/common/Config.sol";
import {
    EmptyProofLength,
    InvalidDisabledProofSystemsMask,
    InvalidProofFormat,
    UnknownVerifierType
} from "contracts/common/L1ContractErrors.sol";

/// @notice Records whether it was reached, and with which proof, without needing storage.
contract LaneVerifier is IVerifier {
    error Reached(uint256 firstProofWord, uint256 proofLength, uint256 publicInput);

    bool internal immutable SHOULD_REVEAL;
    bool internal immutable RESULT;

    constructor(bool _shouldReveal, bool _result) {
        SHOULD_REVEAL = _shouldReveal;
        RESULT = _result;
    }

    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external view returns (bool) {
        if (SHOULD_REVEAL) {
            revert Reached(_proof.length == 0 ? type(uint256).max : _proof[0], _proof.length, _publicInputs[0]);
        }
        return RESULT;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Chain stand-in answering the `disabledProofSystems` getter the verifier reads from its caller.
contract ChainStub {
    uint8 public disabledProofSystems;

    function setDisabledProofSystems(uint8 _mask) external {
        disabledProofSystems = _mask;
    }

    function callVerify(
        EraMultiProofVerifier _verifier,
        uint256[] calldata _pi,
        uint256[] calldata _proof
    ) external view returns (bool) {
        return _verifier.verify(_pi, _proof);
    }
}

/// @notice Unit tests for the Era dual-prover gate.
/// @dev Both proof systems are required unless the calling chain has switched one off. One verifier instance
/// serves every chain of a protocol version, so the requirement is read from the caller, which is the chain's
/// own diamond.
contract EraMultiProofVerifierTest is Test {
    EraMultiProofVerifier internal verifier;
    LaneVerifier internal boojum;
    LaneVerifier internal airbender;
    ChainStub internal chain;

    uint256 internal constant RAW_PUBLIC_INPUT = uint256(keccak256("untruncated-transition-hash"));
    /// Distinct from the Boojum word, so routing the wrong one to a lane is caught rather than
    /// passing by coincidence.
    uint256 internal constant RAW_AIRBENDER_PUBLIC_INPUT = uint256(keccak256("airbender-transition-hash"));
    uint256 internal constant BOOJUM_SEGMENT_LENGTH = 3;

    function setUp() public {
        boojum = new LaneVerifier(false, true);
        airbender = new LaneVerifier(false, true);
        verifier = new EraMultiProofVerifier(IVerifier(address(boojum)), IVerifier(address(airbender)));
        chain = new ChainStub();
    }

    /// `[boojum, airbender]` — the two systems commit to different `auxiliaryOutputHash` values, so
    /// a batch has a different transition hash under each.
    function _publicInputs() internal pure returns (uint256[] memory pi) {
        pi = new uint256[](2);
        pi[0] = RAW_PUBLIC_INPUT;
        pi[1] = RAW_AIRBENDER_PUBLIC_INPUT;
    }

    /// `[type, nBoojum, boojum..., airbender(44 words)]`
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

    function _default() internal view returns (uint256[] memory) {
        return _proof(1, BOOJUM_SEGMENT_LENGTH);
    }

    function test_constructor_setsLanes() public view {
        assertEq(address(verifier.BOOJUM_VERIFIER()), address(boojum));
        assertEq(address(verifier.AIRBENDER_VERIFIER()), address(airbender));
    }

    function test_acceptsWhenBothLanesAccept() public view {
        assertTrue(chain.callVerify(verifier, _publicInputs(), _default()));
    }

    /// One lane rejecting must fail the batch even though the other accepted.
    function test_revertsWhenBoojumRejects() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(new LaneVerifier(false, false))),
            IVerifier(address(airbender))
        );
        vm.expectRevert(EraMultiProofVerifier.BoojumVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _default());
    }

    function test_revertsWhenAirbenderRejects() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(boojum)),
            IVerifier(address(new LaneVerifier(false, false)))
        );
        vm.expectRevert(EraMultiProofVerifier.AirbenderVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _default());
    }

    /// Each lane must receive the untruncated public input whole; the sub-verifiers own their derivations.
    function test_passesUntruncatedPublicInputToBoojumLane() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(new LaneVerifier(true, true))),
            IVerifier(address(airbender))
        );
        vm.expectRevert(
            abi.encodeWithSelector(LaneVerifier.Reached.selector, uint256(1), BOOJUM_SEGMENT_LENGTH, RAW_PUBLIC_INPUT)
        );
        chain.callVerify(v, _publicInputs(), _default());
    }

    function test_passesUntruncatedPublicInputToAirbenderLane() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(boojum)),
            IVerifier(address(new LaneVerifier(true, true)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                LaneVerifier.Reached.selector,
                uint256(0xa0),
                AIRBENDER_SNARK_PROOF_LENGTH,
                RAW_AIRBENDER_PUBLIC_INPUT
            )
        );
        chain.callVerify(v, _publicInputs(), _default());
    }

    // ============ Disabled proof systems ============

    function test_skipsAirbenderWhenChainDisabledIt() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(boojum)),
            IVerifier(address(new LaneVerifier(false, false)))
        );
        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        assertTrue(chain.callVerify(v, _publicInputs(), _default()));
    }

    function test_skipsBoojumWhenChainDisabledIt() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(new LaneVerifier(false, false))),
            IVerifier(address(airbender))
        );
        chain.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_DISABLED);
        assertTrue(chain.callVerify(v, _publicInputs(), _proof(1, 0)));
    }

    /// A chain that never set a policy must require both.
    function test_defaultPolicyRequiresBothLanes() public {
        EraMultiProofVerifier v = new EraMultiProofVerifier(
            IVerifier(address(boojum)),
            IVerifier(address(new LaneVerifier(false, false)))
        );
        vm.expectRevert(EraMultiProofVerifier.AirbenderVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), _default());
    }

    // ============ Envelope discipline ============

    function test_revertsOnEmptyProof() public {
        vm.expectRevert(EmptyProofLength.selector);
        chain.callVerify(verifier, _publicInputs(), new uint256[](0));
    }

    function test_revertsOnUnknownProofType() public {
        uint256[] memory proof = _default();
        proof[0] = ERA_MULTI_PROOF_TYPE + 1;
        vm.expectRevert(abi.encodeWithSelector(UnknownVerifierType.selector));
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    /// Bits above the type byte are reserved, so a header carrying data in them is refused.
    function test_revertsOnReservedHeaderBits() public {
        uint256[] memory proof = _default();
        proof[0] = ERA_MULTI_PROOF_TYPE | (uint256(1) << 8);
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    /// The Airbender slot is fixed-length, so the envelope length is exact — no trailing bytes.
    function test_revertsOnWrongEnvelopeLength() public {
        uint256[] memory proof = _default();
        uint256[] memory tooLong = new uint256[](proof.length + 1);
        for (uint256 i = 0; i < proof.length; ++i) {
            tooLong[i] = proof[i];
        }
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), tooLong);
    }

    /// The Boojum segment must not accept an Airbender-typed proof. Asserted against the real
    /// `EraDualVerifier` rather than a stand-in: a stub that reimplements the type check would pass even if
    /// the production router had started accepting type 2.
    function test_boojumSegmentCannotCarryAirbenderType() public {
        EraDualVerifier router = new EraDualVerifier(
            IVerifierV2(address(new LaneVerifier(false, true))),
            IVerifier(address(new LaneVerifier(false, true)))
        );
        EraMultiProofVerifier v = new EraMultiProofVerifier(IVerifier(address(router)), IVerifier(address(airbender)));

        vm.expectRevert(UnknownVerifierType.selector);
        chain.callVerify(v, _publicInputs(), _proof(2, BOOJUM_SEGMENT_LENGTH));
    }

    /// A declared Boojum length that would overflow a naive `2 + N + 44` must surface as the envelope
    /// error, not a checked-arithmetic panic.
    function test_revertsOnOutOfRangeBoojumLength() public {
        uint256[] memory proof = _default();
        proof[1] = type(uint256).max;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    function test_revertsOnEnvelopeShorterThanAirbenderSlot() public {
        uint256[] memory proof = new uint256[](2 + AIRBENDER_SNARK_PROOF_LENGTH - 1);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 0;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    function test_revertsOnHeaderOnlyProof() public {
        uint256[] memory proof = new uint256[](1);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        vm.expectRevert(InvalidProofFormat.selector);
        chain.callVerify(verifier, _publicInputs(), proof);
    }

    /// The gate must never accept a batch it verified nothing for, even if a both-disabled mask somehow
    /// reaches storage past the Admin setter's guard.
    function test_revertsWhenChainDisabledEverything() public {
        chain.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidDisabledProofSystemsMask.selector,
                BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED
            )
        );
        chain.callVerify(verifier, _publicInputs(), _default());
    }
}
