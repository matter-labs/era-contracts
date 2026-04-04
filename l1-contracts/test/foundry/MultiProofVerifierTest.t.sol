// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";

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
    }

    function test_deployment() public view {
        assertEq(address(verifier.airbenderVerifier()), address(passVerifier));
        assertEq(address(verifier.ziskVerifier()), address(passVerifier));
    }

    function test_mockProof_passes() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        // Mock proof: [type=3, prevHash=0, magic=13, publicInput]
        uint256[] memory proof = new uint256[](4);
        proof[0] = 3;  // MOCK_PROOF_TYPE
        proof[1] = 0;  // previous hash (0 means use publicInputs[0] directly)
        proof[2] = 13; // magic
        proof[3] = 42; // must match hash(prevHash, publicInputs)

        assertTrue(verifier.verify(publicInputs, proof));
    }

    function test_multiProof_bothPass() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        // Multi-proof: [type=5, prevHash=0, N=2, airbender[0], airbender[1], zisk[0..31]]
        uint256 airbenderLen = 2;
        uint256 ziskLen = 32;
        uint256[] memory proof = new uint256[](3 + airbenderLen + ziskLen);
        proof[0] = 5;  // MULTI_PROOF_TYPE
        proof[1] = 0;  // previous hash
        proof[2] = airbenderLen;
        // Airbender proof elements (mock accepts anything)
        proof[3] = 111;
        proof[4] = 222;
        // ZiSK proof elements (mock accepts anything)
        for (uint256 i = 0; i < ziskLen; i++) {
            proof[5 + i] = i;
        }

        assertTrue(verifier.verify(publicInputs, proof));
    }

    function test_multiProof_airbenderFails_reverts() public {
        // Set airbender verifier to fail.
        verifier.setAirbenderVerifier(IVerifier(address(failVerifier)));

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](3 + 2 + 32);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = 2;

        vm.expectRevert(MultiProofVerifier.AirbenderVerificationFailed.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_multiProof_ziskFails_reverts() public {
        // Set zisk verifier to fail (airbender still passes).
        verifier.setZiskVerifier(IVerifier(address(failVerifier)));

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 42;

        uint256[] memory proof = new uint256[](3 + 2 + 32);
        proof[0] = 5;
        proof[1] = 0;
        proof[2] = 2;

        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_unknownProofType_reverts() public {
        uint256[] memory publicInputs = new uint256[](1);
        uint256[] memory proof = new uint256[](1);
        proof[0] = 99; // unknown type

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 99));
        verifier.verify(publicInputs, proof);
    }

    function test_singleProofType2_rejected() public {
        // Type 2 (single Airbender proof) should be rejected by MultiProofVerifier.
        uint256[] memory publicInputs = new uint256[](1);
        uint256[] memory proof = new uint256[](44);
        proof[0] = 2; // OHBENDER type

        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, 2));
        verifier.verify(publicInputs, proof);
    }

    function test_setVerifiers_onlyOwner() public {
        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        verifier.setAirbenderVerifier(IVerifier(address(failVerifier)));
    }
}
