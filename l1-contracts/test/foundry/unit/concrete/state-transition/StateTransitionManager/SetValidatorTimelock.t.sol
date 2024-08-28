// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";

import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract setValidatorTimelockTest is StateTransitionManagerTest {
    function test_SettingValidatorTimelock() public {
        assertEq(
            chainContractAddress.validatorTimelock(),
            validator,
            "Initial validator timelock address is not correct"
        );

        address newValidatorTimelock = address(0x0000000000000000000000000000000000004235);
        chainContractAddress.setValidatorTimelock(newValidatorTimelock);

        assertEq(
            chainContractAddress.validatorTimelock(),
            newValidatorTimelock,
            "Validator timelock update was not successful"
        );
    }

    function test_RevertWhen_NotOwner() public {
        // Need this because in shared setup we start a prank as the governor
        vm.stopPrank();

        address notOwner = makeAddr("notOwner");
        assertEq(
            chainContractAddress.validatorTimelock(),
            validator,
            "Initial validator timelock address is not correct"
        );

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notOwner));
        address newValidatorTimelock = address(0x0000000000000000000000000000000000004235);
        chainContractAddress.setValidatorTimelock(newValidatorTimelock);

        assertEq(chainContractAddress.validatorTimelock(), validator, "Validator should not have been updated");
    }
}
