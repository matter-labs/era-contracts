// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VerifierTestTest} from "./Verifier.t.sol";
import {DummyTestnetVerifier} from "contracts/dev-contracts/test/DummyTestnetVerifier.sol";

contract TestnetVerifierTest is VerifierTestTest {
    DummyTestnetVerifier testnetVerifier;

    function setUp() public override {
        super.setUp();

        testnetVerifier = new DummyTestnetVerifier();
    }

    function test_revertWhen_blockChainIdIsOne() public {
        vm.chainId(1);

        vm.expectRevert();
        new DummyTestnetVerifier();
    }

    function test_SucceedsWhen_proofIsEmpty() public {
        uint256[] memory publicInputs = new uint256[](1);
        uint256[] memory proof = new uint256[](0);
        uint256[] memory recursiveAggregationInput = new uint256[](0);

        bool result = testnetVerifier.verify(publicInputs, proof, recursiveAggregationInput);

        assertTrue(result);
    }

    function test_SuccessfullyVerifiesProofIfIsNotEmpty() public {
        bool result = testnetVerifier.verify(publicInputs, serializedProof, recursiveAggregationInput);

        assertTrue(result);
    }
}
