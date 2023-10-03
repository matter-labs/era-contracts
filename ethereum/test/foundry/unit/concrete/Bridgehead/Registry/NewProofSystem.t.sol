// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {RegistryTest} from "./_Registry_Shared.t.sol";

contract NewProofSystemTest is RegistryTest {
    function setUp() public {
        proofSystemAddress = makeAddr("proofSystemAddress");
    }

    function test_RevertWhen_NonGovernor() public {
        vm.prank(NON_GOVERNOR);
        vm.expectRevert(bytes.concat("12g"));
        bridgehead.newProofSystem(proofSystemAddress);
    }

    function test_RevertWhen_ProofSystemAlreadyExists() public {
        vm.prank(GOVERNOR);
        bridgehead.newProofSystem(proofSystemAddress);

        vm.prank(GOVERNOR);
        vm.expectRevert(bytes.concat("r35"));
        bridgehead.newProofSystem(proofSystemAddress);
    }

    function test_NewProofSystemSuccessful() public {
        vm.prank(GOVERNOR);
        bridgehead.newProofSystem(proofSystemAddress);

        assertEq(bridgehead.getIsProofSystem(proofSystemAddress), true, "should be true");
        assertEq(bridgehead.getTotaProofSystems(), 1, "should be exactly 1 proof system");
    }
}
