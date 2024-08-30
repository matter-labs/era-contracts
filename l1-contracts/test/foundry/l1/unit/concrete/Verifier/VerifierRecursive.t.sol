// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VerifierTestTest} from "./Verifier.t.sol";
import {VerifierRecursiveTest} from "contracts/dev-contracts/test/VerifierRecursiveTest.sol";

contract VerifierRecursiveTestTest is VerifierTestTest {
    function setUp() public override {
        super.setUp();

        recursiveAggregationInput.push(2257920826825449939414463854743099397427742128922725774525544832270890253504);
        recursiveAggregationInput.push(9091218701914748532331969127001446391756173432977615061129552313204917562530);
        recursiveAggregationInput.push(16188304989094043810949359833767911976672882599560690320245309499206765021563);
        recursiveAggregationInput.push(3201093556796962656759050531176732990872300033146738631772984017549903765305);

        verifier = new VerifierRecursiveTest();
    }

    function testMoreThan4WordsRecursiveInput_shouldRevert() public {
        uint256[] memory newRecursiveAggregationInput = new uint256[](recursiveAggregationInput.length + 1);

        for (uint256 i = 0; i < recursiveAggregationInput.length; i++) {
            newRecursiveAggregationInput[i] = recursiveAggregationInput[i];
        }
        newRecursiveAggregationInput[newRecursiveAggregationInput.length - 1] = recursiveAggregationInput[
            recursiveAggregationInput.length - 1
        ];

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, serializedProof, newRecursiveAggregationInput);
    }

    function testEmptyRecursiveInput_shouldRevert() public {
        uint256[] memory newRecursiveAggregationInput;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, serializedProof, newRecursiveAggregationInput);
    }

    function testInvalidRecursiveInput_shouldRevert() public {
        uint256[] memory newRecursiveAggregationInput = new uint256[](4);
        newRecursiveAggregationInput[0] = 1;
        newRecursiveAggregationInput[1] = 2;
        newRecursiveAggregationInput[2] = 1;
        newRecursiveAggregationInput[3] = 2;

        vm.expectRevert(bytes("finalPairing: pairing failure"));
        verifier.verify(publicInputs, serializedProof, newRecursiveAggregationInput);
    }

    function testVerificationKeyHash() public override {
        bytes32 verificationKeyHash = verifier.verificationKeyHash();
        assertEq(verificationKeyHash, 0x88b3ddc4ed85974c7e14297dcad4097169440305c05fdb6441ca8dfd77cd7fa7);
    }
}
