// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PlonkVerifierTestTest} from "./PlonkVerifier.t.sol";
import {DummyPlonkVerifier} from "contracts/dev-contracts/test/DummyPlonkVerifier.sol";

contract TestnetVerifierTest is PlonkVerifierTestTest {
    DummyPlonkVerifier testnetVerifier;

    function setUp() public override {
        super.setUp();

        testnetVerifier = new DummyPlonkVerifier();
    }

    function test_revertWhen_blockChainIdIsOne() public {
        vm.chainId(1);

        vm.expectRevert();
        new DummyPlonkVerifier();
    }

    function test_SucceedsWhen_proofIsEmpty() public {
        uint256[] memory emptyPublicInputs = new uint256[](1);
        uint256[] memory emptyProof = new uint256[](0);

        bool result = testnetVerifier.verify(emptyPublicInputs, emptyProof);

        assertTrue(result);
    }

    function test_SuccessfullyVerifiesProofIfIsNotEmpty() public {
        bool result = testnetVerifier.verify(publicInputs, serializedProof);

        assertTrue(result);
    }
}
