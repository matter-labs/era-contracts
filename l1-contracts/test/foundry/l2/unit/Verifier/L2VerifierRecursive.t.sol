// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L2PlonkVerifierTestTest} from "./L2PlonkVerifier.t.sol";
import {L2PlonkVerifierRecursiveTest} from "contracts/dev-contracts/test/L2PlonkVerifierRecursiveTest.sol";
contract L2PlonkVerifierRecursiveTestTest is L2PlonkVerifierTestTest {
    function setUp() public override {
        super.setUp();

        serializedProof.push(2257920826825449939414463854743099397427742128922725774525544832270890253504);
        serializedProof.push(9091218701914748532331969127001446391756173432977615061129552313204917562530);
        serializedProof.push(16188304989094043810949359833767911976672882599560690320245309499206765021563);
        serializedProof.push(3201093556796962656759050531176732990872300033146738631772984017549903765305);

        verifier = new L2PlonkVerifierRecursiveTest();
    }

    function testMoreThan4WordsRecursiveInput_shouldRevert() public {
        uint256[] memory newSerializedProof = new uint256[](serializedProof.length + 1);

        for (uint256 i = 0; i < serializedProof.length; i++) {
            newSerializedProof[i] = serializedProof[i];
        }
        newSerializedProof[newSerializedProof.length - 1] = serializedProof[serializedProof.length - 1];

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, newSerializedProof);
    }

    function testEmptyRecursiveInput_shouldRevert() public {
        uint256[] memory newSerializedProof = new uint256[](serializedProof.length - 4);
        for (uint256 i = 0; i < newSerializedProof.length; i++) {
            newSerializedProof[i] = serializedProof[i];
        }

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, newSerializedProof);
    }

    function testInvalidRecursiveInput_shouldRevert() public {
        uint256[] memory newSerializedProof = serializedProof;
        newSerializedProof[newSerializedProof.length - 4] = 1;
        newSerializedProof[newSerializedProof.length - 3] = 2;
        newSerializedProof[newSerializedProof.length - 2] = 1;
        newSerializedProof[newSerializedProof.length - 1] = 2;

        vm.expectRevert(bytes("finalPairing: pairing failure"));
        verifier.verify(publicInputs, newSerializedProof);
    }

    function testVerificationKeyHash() public override {
        bytes32 verificationKeyHash = verifier.verificationKeyHash();
        assertEq(verificationKeyHash, 0x88b3ddc4ed85974c7e14297dcad4097169440305c05fdb6441ca8dfd77cd7fa7);
    }
}
