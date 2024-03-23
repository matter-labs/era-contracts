// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";

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
}
