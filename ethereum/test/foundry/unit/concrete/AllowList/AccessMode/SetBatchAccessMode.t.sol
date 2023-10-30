// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AccessModeTest} from "./_AccessMode_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";

contract SetBatchAccessModeTest is AccessModeTest {
    function test_RevertWhen_NonOwner() public {
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        IAllowList.AccessMode[] memory accessModes = new IAllowList.AccessMode[](2);
        accessModes[0] = IAllowList.AccessMode.Public;
        accessModes[1] = IAllowList.AccessMode.Public;

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(randomSigner);
        allowList.setBatchAccessMode(targets, accessModes);
    }

    function test_Owner() public {
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        IAllowList.AccessMode[] memory accessModes = new IAllowList.AccessMode[](2);
        accessModes[0] = IAllowList.AccessMode.Public;
        accessModes[1] = IAllowList.AccessMode.Public;

        vm.prank(owner);
        allowList.setBatchAccessMode(targets, accessModes);
    }

    function test_RevertWhen_ArrayLengthNotEqual() public {
        address[] memory targets = new address[](1);
        targets[0] = target;

        IAllowList.AccessMode[] memory accessModes = new IAllowList.AccessMode[](2);
        accessModes[0] = IAllowList.AccessMode.Public;
        accessModes[1] = IAllowList.AccessMode.Public;

        vm.expectRevert(abi.encodePacked("yg"));
        vm.prank(owner);
        allowList.setBatchAccessMode(targets, accessModes);
    }
}
