// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract setNewVersionUpgradeTest is StateTransitionManagerTest {
    function test_SettingNewVersionUpgrade() public {
        assertEq(chainContractAddress.protocolVersion(), 0, "Initial protocol version is not correct");

        address randomDiamondInit = address(0x303030303030303030303);
        Diamond.DiamondCutData memory newDiamondCutData = getDiamondCutData(address(randomDiamondInit));
        bytes32 newCutHash = keccak256(abi.encode(newDiamondCutData));

        chainContractAddress.setNewVersionUpgrade(newDiamondCutData, 0, 999999999999, 1);

        assertEq(chainContractAddress.upgradeCutHash(0), newCutHash, "Diamond cut upgrade was not successful");
        assertEq(chainContractAddress.protocolVersion(), 1, "New protocol version is not correct");
    }
}
