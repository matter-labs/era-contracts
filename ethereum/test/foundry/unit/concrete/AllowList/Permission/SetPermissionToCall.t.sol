// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {PermissionTest} from "./_Permission_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";

contract SetPermissionToCallTest is PermissionTest {
    function test_RevertWhen_NonOwner() public {
        vm.expectRevert(abi.encodePacked("Ownable: caller is not the owner"));
        vm.prank(randomSigner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
    }

    function test_Owner() public {
        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
    }

    function test_OwnerTwice() public {
        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);

        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
    }

    function test_PermissionBefore() public {
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(randomSigner, target, functionSig);
        assertEq(hasSpecialAccessToCall, false, "hasSpecialAccessToCall should be false");

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isClosed = accessMode == IAllowList.AccessMode.Closed;
        assertEq(isClosed, true, "accessMode should be Closed");

        bool canCall = allowList.canCall(randomSigner, target, functionSig);
        assertEq(canCall, false, "canCall should be false");
    }

    function test_PermissionAfter() public {
        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(randomSigner, target, functionSig);
        assertEq(hasSpecialAccessToCall, true, "hasSpecialAccessToCall should be true");

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isClosed = accessMode == IAllowList.AccessMode.Closed;
        assertEq(isClosed, true, "accessMode should be Closed");

        bool canCall = allowList.canCall(randomSigner, target, functionSig);
        assertEq(canCall, false, "canCall should be false");
    }

    function test_RemovePermission() public {
        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(randomSigner, target, functionSig);
        assertEq(hasSpecialAccessToCall, true, "should be true");

        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, false);

        hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(randomSigner, target, functionSig);
        assertEq(hasSpecialAccessToCall, false, "hasSpecialAccessToCall should be false");
    }
}
