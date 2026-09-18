// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraMultiProofTestnetVerifier} from "contracts/state-transition/verifiers/EraMultiProofTestnetVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    AIRBENDER_PROOF_SYSTEM_MASK,
    AIRBENDER_SNARK_PROOF_LENGTH,
    BOOJUM_FFLONK_PROOF_LENGTH,
    ERA_MULTI_PROOF_TYPE
} from "contracts/common/Config.sol";
import {AirbenderVerificationFailed} from "contracts/common/L1ContractErrors.sol";
import {ChainStub, StubVerifier} from "./VerifierStubs.sol";

contract EraMultiProofTestnetVerifierTest is Test {
    EraMultiProofTestnetVerifier internal verifier;
    ChainStub internal chain;

    function setUp() public {
        verifier = new EraMultiProofTestnetVerifier(
            IVerifier(address(new StubVerifier(true, bytes32(0)))),
            IVerifier(address(new StubVerifier(false, bytes32(0))))
        );
        chain = new ChainStub();
    }

    function _publicInputs() internal pure returns (uint256[] memory pi) {
        pi = new uint256[](2);
        pi[0] = uint256(keccak256("boojum"));
        pi[1] = uint256(keccak256("airbender"));
    }

    function _proof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](1 + BOOJUM_FFLONK_PROOF_LENGTH + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
    }

    function test_isTestnetVerifier() public view {
        assertTrue(verifier.IS_TESTNET_VERIFIER());
    }

    /// An empty proof skips verification.
    function test_acceptsEmptyProof() public view {
        assertTrue(chain.callVerify(verifier, _publicInputs(), new uint256[](0)));
    }

    function test_nonEmptyProofUsesRealPath() public {
        vm.expectRevert(AirbenderVerificationFailed.selector);
        chain.callVerify(verifier, _publicInputs(), _proof());
    }

    function test_disabledSystemsAreHonoured() public {
        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        assertTrue(chain.callVerify(verifier, _publicInputs(), _proof()));
    }

    function test_reportsVerificationKeys() public {
        EraMultiProofTestnetVerifier v = new EraMultiProofTestnetVerifier(
            IVerifier(address(new StubVerifier(true, keccak256("boojum-key")))),
            IVerifier(address(new StubVerifier(true, keccak256("airbender-key"))))
        );

        assertEq(v.verificationKeyHash(), keccak256("boojum-key"));
        assertEq(v.verificationKeyHash(0), keccak256("boojum-key"));
        assertEq(v.verificationKeyHash(2), keccak256("airbender-key"));
    }
}
