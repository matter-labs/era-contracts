// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract setUpgradeDiamondCutTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_SettingUpgradeDiamondCut() public {
        assertEq(chainContractAddress.protocolVersion(), 0, "Initial protocol version is not correct");

        address randomDiamondInit = address(0x303030303030303030303);
        Diamond.DiamondCutData memory newDiamondCutData = getDiamondCutData(address(randomDiamondInit));
        bytes32 newCutHash = keccak256(abi.encode(newDiamondCutData));

        chainContractAddress.setUpgradeDiamondCut(newDiamondCutData, 0);

        assertEq(chainContractAddress.upgradeCutHash(0), newCutHash, "Diamond cut upgrade was not successful");
        assertEq(chainContractAddress.protocolVersion(), 0, "Protocol version should not change");
    }
}
