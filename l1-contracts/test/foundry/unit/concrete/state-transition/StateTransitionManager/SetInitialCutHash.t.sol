// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract setInitialCutHashTest is StateTransitionManagerTest {
    function test_SettingInitialCutHash() public {
        bytes32 initialCutHash = keccak256(abi.encode(getDiamondCutData(address(diamondInit))));
        address randomDiamondInit = address(0x303030303030303030303);

        assertEq(chainContractAddress.initialCutHash(), initialCutHash, "Initial cut hash is not correct");

        Diamond.DiamondCutData memory newDiamondCutData = getDiamondCutData(address(randomDiamondInit));
        bytes32 newCutHash = keccak256(abi.encode(newDiamondCutData));

        chainContractAddress.setInitialCutHash(newDiamondCutData);

        assertEq(chainContractAddress.initialCutHash(), newCutHash, "Initial cut hash update was not successful");
    }
}
