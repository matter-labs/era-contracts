// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {PermissionTest} from "./_Permission_Shared.t.sol";

contract SetBatchPermissionToCall is PermissionTest {
    function test_RevertWhen_NonOwner() public {
        address[] memory callers = new address[](2);
        callers[0] = owner;
        callers[1] = owner;

        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        bytes4[] memory functionSigs = new bytes4[](2);
        functionSigs[0] = functionSig;
        functionSigs[1] = functionSig;

        bool[] memory enables = new bool[](2);
        enables[0] = true;
        enables[1] = true;

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(randomSigner);
        allowList.setBatchPermissionToCall(callers, targets, functionSigs, enables);
    }

    function test_Owner() public {
        address[] memory callers = new address[](2);
        callers[0] = owner;
        callers[1] = owner;

        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        bytes4[] memory functionSigs = new bytes4[](2);
        functionSigs[0] = functionSig;
        functionSigs[1] = functionSig;

        bool[] memory enables = new bool[](2);
        enables[0] = true;
        enables[1] = true;

        vm.prank(owner);
        allowList.setBatchPermissionToCall(callers, targets, functionSigs, enables);
    }

    function test_RevertWhen_ArrayLengthNotEqual() public {
        address[] memory callers = new address[](1);
        callers[0] = owner;

        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        bytes4[] memory functionSigs = new bytes4[](2);
        functionSigs[0] = functionSig;
        functionSigs[1] = functionSig;

        bool[] memory enables = new bool[](2);
        enables[0] = true;
        enables[1] = true;

        vm.expectRevert(abi.encodePacked("yw"));
        vm.prank(owner);
        allowList.setBatchPermissionToCall(callers, targets, functionSigs, enables);
    }
}
