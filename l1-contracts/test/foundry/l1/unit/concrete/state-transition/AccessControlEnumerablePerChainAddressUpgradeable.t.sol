// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "contracts/state-transition/AccessControlEnumerablePerChainAddressUpgradeable.sol";
import {RoleAccessDenied, DefaultAdminTransferNotAllowed} from "contracts/common/L1ContractErrors.sol";

// Mock implementation for testing
contract MockAccessControlEnumerable is AccessControlEnumerablePerChainAddressUpgradeable {
    function _getChainAdmin(address _chainAddress) internal view override returns (address) {
        return _chainAddress; // For testing, we'll use the chain address as its admin
    }
}

contract AccessControlEnumerablePerChainAddressUpgradeableTest is Test {
    MockAccessControlEnumerable accessControl;

    address chainAddress1 = address(0x1);
    address chainAddress2 = address(0x2);
    address account1 = address(0x3);
    address account2 = address(0x4);
    bytes32 role1 = keccak256("ROLE_1");
    bytes32 role2 = keccak256("ROLE_2");

    event RoleGranted(address indexed chainAddress, bytes32 indexed role, address indexed account);
    event RoleRevoked(address indexed chainAddress, bytes32 indexed role, address indexed account);
    event RoleAdminChanged(
        address indexed chainAddress,
        bytes32 indexed role,
        bytes32 previousAdminRole,
        bytes32 newAdminRole
    );

    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function setUp() public {
        accessControl = new MockAccessControlEnumerable();
    }

    function test_HasRole() public {
        // Test DEFAULT_ADMIN_ROLE
        assertTrue(accessControl.hasRole(chainAddress1, DEFAULT_ADMIN_ROLE, chainAddress1));
        assertFalse(accessControl.hasRole(chainAddress1, DEFAULT_ADMIN_ROLE, account1));

        // Test custom role
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);
        assertTrue(accessControl.hasRole(chainAddress1, role1, account1));
        assertFalse(accessControl.hasRole(chainAddress1, role1, account2));
    }

    function test_GetRoleAdmin() public {
        // Test DEFAULT_ADMIN_ROLE
        assertEq(accessControl.getRoleAdmin(chainAddress1, DEFAULT_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);

        // Test custom role
        vm.prank(chainAddress1);
        accessControl.setRoleAdmin(chainAddress1, role1, role2);
        assertEq(accessControl.getRoleAdmin(chainAddress1, role1), role2);
    }

    function test_GrantRole() public {
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(chainAddress1, role1, account1);

        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);

        assertTrue(accessControl.hasRole(chainAddress1, role1, account1));
    }

    function test_GrantRoleRevertsForDefaultAdmin() public {
        vm.expectRevert(DefaultAdminTransferNotAllowed.selector);
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, DEFAULT_ADMIN_ROLE, account1);
    }

    function test_RevokeRole() public {
        // First grant the role
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);

        // Then revoke it
        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(chainAddress1, role1, account1);

        vm.prank(chainAddress1);
        accessControl.revokeRole(chainAddress1, role1, account1);

        assertFalse(accessControl.hasRole(chainAddress1, role1, account1));
    }

    function test_RenounceRole() public {
        // First grant the role
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);

        // Then renounce it
        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(chainAddress1, role1, account1);

        vm.prank(account1);
        accessControl.renounceRole(chainAddress1, role1);

        assertFalse(accessControl.hasRole(chainAddress1, role1, account1));
    }

    function test_SetRoleAdmin() public {
        vm.expectEmit(true, true, false, true);
        emit RoleAdminChanged(chainAddress1, role1, DEFAULT_ADMIN_ROLE, role2);

        vm.prank(chainAddress1);
        accessControl.setRoleAdmin(chainAddress1, role1, role2);

        assertEq(accessControl.getRoleAdmin(chainAddress1, role1), role2);
    }

    function test_SetRoleAdminRevertsForDefaultAdmin() public {
        vm.prank(chainAddress1);
        vm.expectRevert(DefaultAdminTransferNotAllowed.selector);
        accessControl.setRoleAdmin(chainAddress1, DEFAULT_ADMIN_ROLE, role1);
    }

    function test_GetRoleMember() public {
        // Grant roles to multiple accounts
        vm.startPrank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);
        accessControl.grantRole(chainAddress1, role1, account2);
        vm.stopPrank();

        // Check that we can get both members
        assertEq(accessControl.getRoleMember(chainAddress1, role1, 0), account1);
        assertEq(accessControl.getRoleMember(chainAddress1, role1, 1), account2);
    }

    function test_GetRoleMemberCount() public {
        // Initially no members
        assertEq(accessControl.getRoleMemberCount(chainAddress1, role1), 0);

        // Add one member
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);
        assertEq(accessControl.getRoleMemberCount(chainAddress1, role1), 1);

        // Add another member
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account2);
        assertEq(accessControl.getRoleMemberCount(chainAddress1, role1), 2);
    }

    function test_CrossChainRoleIsolation() public {
        // Grant role on chain1
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);

        // Verify role is not granted on chain2
        assertFalse(accessControl.hasRole(chainAddress2, role1, account1));

        // Grant role on chain2
        vm.prank(chainAddress2);
        accessControl.grantRole(chainAddress2, role1, account1);

        // Verify roles are isolated
        assertTrue(accessControl.hasRole(chainAddress1, role1, account1));
        assertTrue(accessControl.hasRole(chainAddress2, role1, account1));
    }

    // Admin / authorization path tests
    function test_GrantRoleByNonAdminReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress1, DEFAULT_ADMIN_ROLE, account1));
        vm.prank(account1);
        accessControl.grantRole(chainAddress1, role1, account2);
    }

    function test_RevokeRoleByNonAdminReverts() public {
        // First grant the role
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);

        // Try to revoke as non-admin
        vm.prank(account2);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress1, DEFAULT_ADMIN_ROLE, account2));
        accessControl.revokeRole(chainAddress1, role1, account1);
    }

    function test_SetRoleAdminByNonAdminReverts() public {
        vm.prank(account1);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress1, DEFAULT_ADMIN_ROLE, account1));
        accessControl.setRoleAdmin(chainAddress1, role1, role2);
    }

    function test_RenounceRoleByNonHolderReverts() public {
        vm.prank(account2);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress1, role1, account2));
        accessControl.renounceRole(chainAddress1, role1);
    }

    // Idempotency / edge behavior tests
    function test_GrantRoleTwiceIsNoOp() public {
        // First grant
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);
        uint256 initialCount = accessControl.getRoleMemberCount(chainAddress1, role1);

        // Second grant - should not emit event
        vm.prank(chainAddress1);
        accessControl.grantRole(chainAddress1, role1, account1);

        // Verify member count unchanged
        assertEq(accessControl.getRoleMemberCount(chainAddress1, role1), initialCount);
    }

    function test_RevokeNonExistentRoleIsNoOp() public {
        uint256 initialCount = accessControl.getRoleMemberCount(chainAddress1, role1);

        // Try to revoke non-existent role
        vm.prank(chainAddress1);
        accessControl.revokeRole(chainAddress1, role1, account1);

        // Verify member count unchanged
        assertEq(accessControl.getRoleMemberCount(chainAddress1, role1), initialCount);
    }

    function test_GetRoleMemberOutOfBoundsReverts() public {
        vm.prank(chainAddress1);
        vm.expectRevert();
        accessControl.getRoleMember(chainAddress1, role1, 0);
    }

    function test_EnumerationFunctionsOnDefaultAdminRole() public {
        assertEq(accessControl.getRoleMember(chainAddress1, DEFAULT_ADMIN_ROLE, 0), chainAddress1);
        assertEq(accessControl.getRoleMemberCount(chainAddress1, DEFAULT_ADMIN_ROLE), 1);
    }
}
