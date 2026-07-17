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

contract MultiProofVerifierTest is Test {
    MultiProofVerifier verifier;
    MultiProofTestnetVerifier testnetVerifier;
    MockPassVerifier passVerifier;
    MockFailVerifier failVerifier;

    function setUp() public {
        passVerifier = new MockPassVerifier();
        failVerifier = new MockFailVerifier();
        verifier = new MultiProofVerifier(
            IVerifier(address(passVerifier)),
            IVerifier(address(passVerifier)),
            address(this)
        );
        // MultiProofTestnetVerifier wraps MultiProofVerifier — adds mock proof support.
        testnetVerifier = new MultiProofTestnetVerifier(IVerifier(address(verifier)));
    }

    // --- MultiProofVerifier (prod) tests ---

    function test_deployment() public view {
        assertEq(address(verifier.airbenderVerifier()), address(passVerifier));
        assertEq(address(verifier.ziskVerifier()), address(passVerifier));
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
        verifier.setZiskVerifier(IVerifier(address(failVerifier)));

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
