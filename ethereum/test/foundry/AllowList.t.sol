// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../contracts/common/AllowList.sol";
import "../../contracts/common/interfaces/IAllowList.sol";

contract AllowListTest is Test {
    AllowList allowList;
    address owner = makeAddr("owner");
    address randomSigner = makeAddr("randomSigner");

    function setUp() public {
        allowList = new AllowList(owner);
    }
}

contract PermissionTest is AllowListTest {
    address target = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    bytes4 functionSig = 0x1626ba7e;
}

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
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            randomSigner,
            target,
            functionSig
        );
        assertEq(
            hasSpecialAccessToCall,
            false,
            "hasSpecialAccessToCall should be false"
        );

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isClosed = accessMode == IAllowList.AccessMode.Closed;
        assertEq(isClosed, true, "accessMode should be Closed");

        bool canCall = allowList.canCall(randomSigner, target, functionSig);
        assertEq(canCall, false, "canCall should be false");
    }

    function test_PermissionAfter() public {
        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            randomSigner,
            target,
            functionSig
        );
        assertEq(
            hasSpecialAccessToCall,
            true,
            "hasSpecialAccessToCall should be true"
        );

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isClosed = accessMode == IAllowList.AccessMode.Closed;
        assertEq(isClosed, true, "accessMode should be Closed");

        bool canCall = allowList.canCall(randomSigner, target, functionSig);
        assertEq(canCall, false, "canCall should be false");
    }

    function test_RemovePermission() public {
        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, true);
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            randomSigner,
            target,
            functionSig
        );
        assertEq(hasSpecialAccessToCall, true, "should be true");

        vm.prank(owner);
        allowList.setPermissionToCall(randomSigner, target, functionSig, false);

        hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            randomSigner,
            target,
            functionSig
        );
        assertEq(
            hasSpecialAccessToCall,
            false,
            "hasSpecialAccessToCall should be false"
        );
    }
}

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
        allowList.setBatchPermissionToCall(
            callers,
            targets,
            functionSigs,
            enables
        );
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
        allowList.setBatchPermissionToCall(
            callers,
            targets,
            functionSigs,
            enables
        );
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
        allowList.setBatchPermissionToCall(
            callers,
            targets,
            functionSigs,
            enables
        );
    }
}

contract AccessModeTest is AllowListTest {
    address target = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    bytes4 functionSig = 0xdeadbeaf;
}

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
        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            owner,
            target,
            functionSig
        );
        assertEq(
            hasSpecialAccessToCall,
            false,
            "hasSpecialAccessToCall should be false"
        );

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isClosed = accessMode == IAllowList.AccessMode.Closed;
        assertEq(isClosed, true, "AccessMode should be Closed");

        bool canCall = allowList.canCall(owner, target, functionSig);
        assertEq(canCall, false, "canCall should be false");
    }

    function test_AccessModeAfter() public {
        vm.prank(owner);
        allowList.setAccessMode(target, IAllowList.AccessMode.Public);

        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            owner,
            target,
            functionSig
        );
        assertEq(
            hasSpecialAccessToCall,
            false,
            "hasSpecialAccessToCall should be false"
        );

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

        bool hasSpecialAccessToCall = allowList.hasSpecialAccessToCall(
            owner,
            target,
            functionSig
        );
        assertEq(
            hasSpecialAccessToCall,
            false,
            "hasSpecialAccessToCall should be false"
        );

        IAllowList.AccessMode accessMode = allowList.getAccessMode(target);
        bool isPublic = accessMode == IAllowList.AccessMode.Public;
        assertEq(isPublic, true, "AccessMode should be Public");

        bool canCall = allowList.canCall(owner, target, functionSig);
        assertEq(canCall, true, "canCall should be true");
    }
}

contract SetBatchAccessModeTest is AccessModeTest {
    function test_RevertWhen_NonOwner() public {
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        IAllowList.AccessMode[]
            memory accessModes = new IAllowList.AccessMode[](2);
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

        IAllowList.AccessMode[]
            memory accessModes = new IAllowList.AccessMode[](2);
        accessModes[0] = IAllowList.AccessMode.Public;
        accessModes[1] = IAllowList.AccessMode.Public;

        vm.prank(owner);
        allowList.setBatchAccessMode(targets, accessModes);
    }

    function test_RevertWhen_ArrayLengthNotEqual() public {
        address[] memory targets = new address[](1);
        targets[0] = target;

        IAllowList.AccessMode[]
            memory accessModes = new IAllowList.AccessMode[](2);
        accessModes[0] = IAllowList.AccessMode.Public;
        accessModes[1] = IAllowList.AccessMode.Public;

        vm.expectRevert(abi.encodePacked("yg"));
        vm.prank(owner);
        allowList.setBatchAccessMode(targets, accessModes);
    }
}

contract DepositLimitTest is AllowListTest {
    address l1token = makeAddr("l1token");

    function test_RevertWhen_NonOwner() public {
        vm.expectRevert(abi.encodePacked("Ownable: caller is not the owner"));
        vm.prank(randomSigner);
        allowList.setDepositLimit(l1token, true, 1000);
    }

    function test_Owner() public {
        vm.prank(owner);
        allowList.setDepositLimit(l1token, true, 1000);

        IAllowList.Deposit memory deposit = allowList.getTokenDepositLimitData(
            l1token
        );
        assertEq(
            deposit.depositLimitation,
            true,
            "depositLimitation should be true"
        );
        assertEq(deposit.depositCap, 1000, "depositCap should be 1000");
    }

    function test_UnlimitedToken() public {
        address unlimitedToken = makeAddr("unlimitedToken");

        IAllowList.Deposit memory deposit = allowList.getTokenDepositLimitData(
            unlimitedToken
        );

        assertEq(
            deposit.depositLimitation,
            false,
            "depositLimitation should be false"
        );
        assertEq(deposit.depositCap, 0, "depositCap should be 0");
    }
}
