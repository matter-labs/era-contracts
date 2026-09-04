// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraMultiProofTestnetVerifier} from "contracts/state-transition/verifiers/EraMultiProofTestnetVerifier.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    AIRBENDER_PROOF_SYSTEM_DISABLED,
    AIRBENDER_SNARK_PROOF_LENGTH,
    ERA_MULTI_PROOF_TYPE
} from "contracts/common/Config.sol";

contract AcceptingVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract RejectingVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return false;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract ChainStub {
    uint8 public disabledProofSystems;

    function setDisabledProofSystems(uint8 _mask) external {
        disabledProofSystems = _mask;
    }

    function callVerify(
        IVerifier _verifier,
        uint256[] calldata _pi,
        uint256[] calldata _proof
    ) external view returns (bool) {
        return _verifier.verify(_pi, _proof);
    }
}

/// @notice Unit tests for the testnet variant of the Era dual-prover gate.
/// @dev It inherits the production verifier rather than wrapping it. A wrapper would become the `msg.sender`
/// the production contract reads `disabledProofSystems` from, which is why the ZKsync OS lane's testnet
/// wrapper cannot answer for the chain. Inheriting keeps the chain's diamond as the caller, so the setting
/// behaves identically on testnet and mainnet and can be tested before it is needed.
contract EraMultiProofTestnetVerifierTest is Test {
    EraMultiProofTestnetVerifier internal verifier;
    ChainStub internal chain;

    function setUp() public {
        verifier = new EraMultiProofTestnetVerifier(
            IVerifier(address(new AcceptingVerifier())),
            IVerifier(address(new RejectingVerifier()))
        );
        chain = new ChainStub();
    }

    function _publicInputs() internal pure returns (uint256[] memory pi) {
        pi = new uint256[](2);
        pi[0] = uint256(keccak256("raw"));
        pi[1] = uint256(keccak256("raw-airbender"));
    }

    function _proof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](2 + 1 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 1;
        proof[2] = 1;
    }

    function test_isTestnetVerifier() public view {
        assertTrue(verifier.IS_TESTNET_VERIFIER());
    }

    /// The testnet convenience: an empty proof skips verification entirely.
    function test_acceptsEmptyProof() public view {
        assertTrue(chain.callVerify(verifier, _publicInputs(), new uint256[](0)));
    }

    /// Anything else goes through the real path, so a failing lane still fails.
    function test_nonEmptyProofUsesRealPath() public {
        vm.expectRevert(EraMultiProofVerifier.AirbenderVerificationFailed.selector);
        chain.callVerify(verifier, _publicInputs(), _proof());
    }

    /// Inheriting means `disabledProofSystems` is read from the chain rather than from a wrapper, so it
    /// takes effect on testnets too.
    function test_disabledSystemsAreHonouredOnTestnet() public {
        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        assertTrue(chain.callVerify(verifier, _publicInputs(), _proof()));
    }

    /// A non-empty envelope must not be able to declare a zero-length Boojum slice and settle without a
    /// Boojum proof. The inner router treating an empty proof as "skip" is exactly how that happened.
    function test_rejectsEmptyBoojumSliceWhileBoojumEnabled() public {
        EraMultiProofTestnetVerifier v = new EraMultiProofTestnetVerifier(
            IVerifier(address(new AcceptingVerifier())),
            IVerifier(address(new AcceptingVerifier()))
        );

        uint256[] memory proof = new uint256[](2 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 0;

        vm.expectRevert(EraMultiProofVerifier.BoojumVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), proof);
    }

    /// The same envelope with Airbender also switched off must not settle a batch with nothing verified.
    function test_rejectsEnvelopeThatWouldVerifyNothing() public {
        EraMultiProofTestnetVerifier v = new EraMultiProofTestnetVerifier(
            IVerifier(address(new AcceptingVerifier())),
            IVerifier(address(new AcceptingVerifier()))
        );
        chain.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);

        uint256[] memory proof = new uint256[](2 + AIRBENDER_SNARK_PROOF_LENGTH);
        proof[0] = ERA_MULTI_PROOF_TYPE;
        proof[1] = 0;

        vm.expectRevert(EraMultiProofVerifier.BoojumVerificationFailed.selector);
        chain.callVerify(v, _publicInputs(), proof);
    }
}
