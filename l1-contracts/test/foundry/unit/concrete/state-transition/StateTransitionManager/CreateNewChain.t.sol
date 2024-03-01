// // SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";

contract createNewChainTest is StateTransitionManagerTest {
    function testCreationOfNewChain() public {
        address baseToken = address(0x3030303);
        address sharedBridge = address(0x4040404);
        address admin = bridgehub;

        vm.stopPrank();
        vm.startPrank(bridgehub);

        chainContractAddress.createNewChain(1, baseToken, sharedBridge, admin, abi.encode(getDiamondCutData(diamondInit)));
        // assertEq(chainContractAddress.validatorTimelock(), initialValidatorTimelock, "Initial validator timelock address is not correct");
        
        // address newValidatorTimelock = address(0x0000000000000000000000000000000000004235);
        // chainContractAddress.setValidatorTimelock(newValidatorTimelock);

        // assertEq(chainContractAddress.validatorTimelock(), newValidatorTimelock, "Validator timelock update was not successful");
    }
}