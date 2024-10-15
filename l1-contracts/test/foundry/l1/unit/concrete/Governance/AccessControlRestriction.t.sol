// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import "forge-std/console.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IAccessControlRestriction} from "contracts/governance/IAccessControlRestriction.sol";
import {Utils} from "test/foundry/l1/unit/concrete/Utils/Utils.sol";
import {ZeroAddress, NoCallsProvided, AccessToFallbackDenied, AccessToFunctionDenied} from "contracts/common/L1ContractErrors.sol";
import {Call} from "contracts/governance/Common.sol";

contract AccessRestrictionTest is Test {
    AccessControlRestriction internal restriction;
    ChainAdmin internal chainAdmin;
    address owner;
    address randomCaller;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function getChainAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = IChainAdmin.getRestrictions.selector;
        selectors[1] = IChainAdmin.isRestrictionActive.selector;
        selectors[2] = IChainAdmin.addRestriction.selector;
        selectors[3] = IChainAdmin.removeRestriction.selector;

        return selectors;
    }

    function setUp() public {
        owner = makeAddr("random address");
        randomCaller = makeAddr("random caller");

        restriction = new AccessControlRestriction(0, owner);
        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);

        chainAdmin = new ChainAdmin(restrictions);
    }

    function test_adminAsAddressZero() public {
        vm.expectRevert("AccessControl: 0 default admin");
        new AccessControlRestriction(0, address(0));
    }

    function test_setRequiredRoleForCallZeroTarget(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        restriction.setRequiredRoleForCall(address(0), bytes4(0), role);
        vm.stopPrank();
    }

    function test_setRequiredRoleForCallByNotDefaultAdmin(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();
        string memory revertMsg = string(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(randomCaller), 20),
                " is missing role ",
                Strings.toHexString(uint256(DEFAULT_ADMIN_ROLE), 32)
            )
        );

        vm.expectRevert(bytes(revertMsg));
        vm.prank(randomCaller);
        restriction.setRequiredRoleForCall(address(chainAdmin), chainAdminSelectors[0], role);
    }

    function test_setRequiredRoleForCallAccessToFunctionDenied(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();

        vm.startPrank(owner);
        restriction.setRequiredRoleForCall(address(chainAdmin), chainAdminSelectors[0], role);
        vm.stopPrank();

        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: abi.encodeCall(IChainAdmin.getRestrictions, ())
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                AccessToFunctionDenied.selector,
                address(chainAdmin),
                chainAdminSelectors[0],
                randomCaller
            )
        );
        restriction.validateCall(call, randomCaller);
    }

    function test_setRequiredRoleForCall(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();

        vm.expectEmit(true, true, false, true);
        emit IAccessControlRestriction.RoleSet(address(chainAdmin), chainAdminSelectors[0], role);

        vm.startPrank(owner);
        restriction.setRequiredRoleForCall(address(chainAdmin), chainAdminSelectors[0], role);
        restriction.grantRole(role, randomCaller);
        vm.stopPrank();

        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: abi.encodeCall(IChainAdmin.getRestrictions, ())
        });
        restriction.validateCall(call, randomCaller);
    }

    function test_setRequiredRoleForFallbackZeroTarget(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        restriction.setRequiredRoleForFallback(address(0), role);
        vm.stopPrank();
    }

    function test_setRequiredRoleForFallbackByNotDefaultAdmin(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        string memory revertMsg = string(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(randomCaller), 20),
                " is missing role ",
                Strings.toHexString(uint256(DEFAULT_ADMIN_ROLE), 32)
            )
        );

        vm.expectRevert(bytes(revertMsg));
        vm.prank(randomCaller);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
    }

    function test_setRequiredRoleForFallbackAccessToFallbackDenied(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        vm.startPrank(owner);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
        vm.stopPrank();

        Call memory call = Call({target: address(chainAdmin), value: 0, data: ""});

        vm.expectRevert(abi.encodeWithSelector(AccessToFallbackDenied.selector, address(chainAdmin), randomCaller));
        restriction.validateCall(call, randomCaller);
    }

    function test_setRequiredRoleForFallback(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        vm.expectEmit(true, false, false, true);
        emit IAccessControlRestriction.FallbackRoleSet(address(chainAdmin), role);

        vm.startPrank(owner);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
        restriction.grantRole(role, randomCaller);
        vm.stopPrank();

        Call memory call = Call({target: address(chainAdmin), value: 0, data: ""});
        restriction.validateCall(call, randomCaller);
    }

    function test_validateCallFunction(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();
        vm.startPrank(owner);
        restriction.setRequiredRoleForCall(address(chainAdmin), chainAdminSelectors[0], role);
        restriction.grantRole(role, randomCaller);
        vm.stopPrank();

        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: abi.encodeCall(IChainAdmin.getRestrictions, ())
        });
        restriction.validateCall(call, randomCaller);
    }

    function test_validateCallFallback(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);
        vm.startPrank(owner);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
        restriction.grantRole(role, randomCaller);
        vm.stopPrank();

        Call memory call = Call({target: address(chainAdmin), value: 0, data: ""});
        restriction.validateCall(call, randomCaller);
    }
}
