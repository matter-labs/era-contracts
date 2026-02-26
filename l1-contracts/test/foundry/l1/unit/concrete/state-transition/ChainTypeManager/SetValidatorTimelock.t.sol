// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";

contract setValidatorTimelockTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_SettingValidatorTimelock() public {
        assertEq(
            chainContractAddress.validatorTimelockPostV29(),
            validator,
            "Initial validator timelock address is not correct"
        );

        address newValidatorTimelock = makeAddr("newValidatorTimelock");

        vm.prank(governor);
        chainContractAddress.setValidatorTimelockPostV29(newValidatorTimelock);

        assertEq(
            chainContractAddress.validatorTimelockPostV29(),
            newValidatorTimelock,
            "Validator timelock update was not successful"
        );
    }

    function test_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        assertEq(
            chainContractAddress.validatorTimelockPostV29(),
            validator,
            "Initial validator timelock address is not correct"
        );

        address newValidatorTimelock = makeAddr("newValidatorTimelock");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setValidatorTimelockPostV29(newValidatorTimelock);

        assertEq(chainContractAddress.validatorTimelockPostV29(), validator, "Validator should not have been updated");
    }
}
