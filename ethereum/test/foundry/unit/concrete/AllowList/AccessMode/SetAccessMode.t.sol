// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {AccessModeTest} from "./_AccessMode_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";

contract SetAccessModeTest is AccessModeTest {
    function test_RevertWhen_NonOwner() public {
        vm.expectRevert(abi.encodePacked("Ownable: caller is not the owner"));
        vm.prank(randomSigner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);
    }

    function test_Owner() public {
        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);
    }

    function test_OwnerTwice() public {
        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);

        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);
    }

    function test_AccessModeBefore() public {
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(owner, target, functionSig);
        assertEq(hasSpecialAccessToCall, false, "hasSpecialAccessToCall should be false");

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isClosed = accessMode == IAllowList.AccessMode.Closed;
        assertEq(isClosed, true, "AccessMode should be Closed");

        bool canCall = allowList.canCall(owner, target, functionSig);
        assertEq(canCall, false, "canCall should be false");
    }

    function test_AccessModeAfter() public {
        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);

        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(owner, target, functionSig);
        assertEq(hasSpecialAccessToCall, false, "hasSpecialAccessToCall should be false");

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isPublic = accessMode == IAllowList.AccessMode.Public;
        assertEq(isPublic, true, "AccessMode should be Public");

        bool canCall = allowList.canCall(owner, target, functionSig);
        assertEq(canCall, true, "canCall should be true");
    }

    function test_RemovePermission() public {
        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Closed);

        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);

        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(owner, target, functionSig);
        assertEq(hasSpecialAccessToCall, false, "hasSpecialAccessToCall should be false");

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isPublic = accessMode == IAllowList.AccessMode.Public;
        assertEq(isPublic, true, "AccessMode should be Public");

        bool canCall = allowList.canCall(owner, target, functionSig);
        assertEq(canCall, true, "canCall should be true");
    }
}
