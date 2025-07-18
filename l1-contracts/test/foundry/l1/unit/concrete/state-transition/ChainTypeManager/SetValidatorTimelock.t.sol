// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";

import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract setValidatorTimelockTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_SettingValidatorTimelock() public {
        assertEq(
            chainContractAddress.validatorTimelock(),
            validator,
            "Initial validator timelock address is not correct"
        );

        address newValidatorTimelock = address(0x0000000000000000000000000000000000004235);
        chainContractAddress.setPostV29UpgradeableValidatorTimelock(newValidatorTimelock);

        assertEq(
            chainContractAddress.postV29UpgradeableValidatorTimelock(),
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
        vm.expectRevert("Ownable: caller is not the owner");
        address newValidatorTimelock = address(0x0000000000000000000000000000000000004235);
        chainContractAddress.setPostV29UpgradeableValidatorTimelock(newValidatorTimelock);

        assertEq(chainContractAddress.postV29UpgradeableValidatorTimelock(), validator, "Validator should not have been updated");
    }
}
