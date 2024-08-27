// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import "forge-std/console.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IAccessControlRestriction} from "contracts/governance/IAccessControlRestriction.sol";
import {Utils} from "test/foundry/unit/concrete/Utils/Utils.sol";
import {NoCallsProvided, AccessToFallbackDenied, AccessToFunctionDenied} from "contracts/common/L1ContractErrors.sol";
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

    function test_setRequiredRoleForCallByNotDefaultAdmin() public {
        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();
        bytes32 role = Utils.randomBytes32("1");
        string memory revertMsg = string(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(randomCaller), 20),
                " is missing role ",
                Strings.toHexString(uint256(DEFAULT_ADMIN_ROLE), 32)
            )
        );

        vm.expectRevert(bytes(revertMsg));
        vm.startPrank(randomCaller);
        restriction.setRequiredRoleForCall(address(chainAdmin), chainAdminSelectors[0], role);
    }

    function test_setRequiredRoleForCall() public {
        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();
        bytes32 role = Utils.randomBytes32("1");

        vm.expectEmit();
        emit IAccessControlRestriction.RoleSet(address(chainAdmin), chainAdminSelectors[0], role);
        vm.prank(owner);
        restriction.setRequiredRoleForCall(address(chainAdmin), chainAdminSelectors[0], role);
    }

    function test_setRequiredRoleForFallbackByNotDefaultAdmin() public {
        bytes32 role = Utils.randomBytes32("1");
        string memory revertMsg = string(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(randomCaller), 20),
                " is missing role ",
                Strings.toHexString(uint256(DEFAULT_ADMIN_ROLE), 32)
            )
        );

        vm.expectRevert(bytes(revertMsg));
        vm.startPrank(randomCaller);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
    }

    function test_setRequiredRoleForFallback() public {
        bytes32 role = Utils.randomBytes32("1");

        vm.expectEmit();
        emit IAccessControlRestriction.FallbackRoleSet(address(chainAdmin), role);
        vm.prank(owner);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
    }

    function test_validateCallFunction() public {
        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();
        bytes32 role = Utils.randomBytes32("1");
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

    function test_validateCallAccessToFunctionDenied() public {
        bytes4[] memory chainAdminSelectors = getChainAdminSelectors();
        bytes32 role = Utils.randomBytes32("1");
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

    function test_validateCallFallback() public {
        bytes32 role = Utils.randomBytes32("1");
        vm.startPrank(owner);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
        restriction.grantRole(role, randomCaller);
        vm.stopPrank();

        Call memory call = Call({target: address(chainAdmin), value: 0, data: ""});
        restriction.validateCall(call, randomCaller);
    }

    function test_validateCAllAccessToFallbackDenied() public {
        bytes32 role = Utils.randomBytes32("1");
        vm.startPrank(owner);
        restriction.setRequiredRoleForFallback(address(chainAdmin), role);
        vm.stopPrank();

        Call memory call = Call({target: address(chainAdmin), value: 0, data: ""});

        vm.expectRevert(abi.encodeWithSelector(AccessToFallbackDenied.selector, address(chainAdmin), randomCaller));
        restriction.validateCall(call, randomCaller);
    }
}