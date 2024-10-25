// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {ZeroAddress, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract L2WrappedBaseTokenStoreTest is Test {
    L2WrappedBaseTokenStore store;

    address owner = address(0x1);
    address admin = address(0x2);
    address other = address(0x3);
    address newAdmin = address(0x4);
    address newPendingAdmin = address(0x5);
    uint256 chainId = 100;
    address l2WBaseToken = address(0xABC);
    address newL2WBaseToken = address(0xDEF);

    // Events
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);
    event NewWBaseTokenAddress(uint256 indexed chainId, address indexed l2WBaseTokenAddress);

    function setUp() public {
        // Deploy the contract with owner and admin
        vm.startPrank(owner);
        store = new L2WrappedBaseTokenStore(owner, admin);
        vm.stopPrank();
    }

    // Deployment Tests
    function testInitialOwner() public {
        assertEq(store.owner(), owner, "Owner should be set correctly");
    }

    function testInitialAdmin() public {
        assertEq(store.admin(), admin, "Admin should be set correctly");
    }

    function testConstructorRevertsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        new L2WrappedBaseTokenStore(address(0), admin);
    }

    function testConstructorRevertsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        new L2WrappedBaseTokenStore(owner, address(0));
    }

    // Access Control Tests
    function testOnlyOwnerOrAdminCanInitializeChain() public {
        // Attempt from owner
        vm.startPrank(owner);
        store.initializeChain(chainId, l2WBaseToken);
        vm.stopPrank();

        // Attempt from admin
        vm.startPrank(admin);
        store.initializeChain(chainId + 1, l2WBaseToken);
        vm.stopPrank();

        // Attempt from other
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, other));
        store.initializeChain(chainId + 2, l2WBaseToken);
        vm.stopPrank();
    }

    function testOnlyOwnerCanReinitializeChain() public {
        // Initialize first
        vm.startPrank(admin);
        store.initializeChain(chainId, l2WBaseToken);
        vm.stopPrank();

        // Reinitialize from owner
        vm.startPrank(owner);
        store.reinitializeChain(chainId, newL2WBaseToken);
        vm.stopPrank();

        // Reinitialize from admin should fail
        vm.startPrank(admin);
        vm.expectRevert("Ownable: caller is not the owner");
        store.reinitializeChain(chainId, l2WBaseToken);
        vm.stopPrank();

        // Reinitialize from other should fail
        vm.startPrank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        store.reinitializeChain(chainId, l2WBaseToken);
        vm.stopPrank();
    }

    // initializeChain Tests
    function testInitializeChain() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit NewWBaseTokenAddress(chainId, l2WBaseToken);
        store.initializeChain(chainId, l2WBaseToken);
        vm.stopPrank();

        address storedAddress = store.l2WBaseTokenAddress(chainId);
        assertEq(storedAddress, l2WBaseToken, "L2 WBaseToken address should be set correctly");
    }

    function testInitializeChainRevertsZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        store.initializeChain(chainId, address(0));
        vm.stopPrank();
    }

    // reinitializeChain Tests
    function testReinitializeChain() public {
        // Initialize first
        vm.startPrank(admin);
        store.initializeChain(chainId, l2WBaseToken);
        vm.stopPrank();

        // Reinitialize
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit NewWBaseTokenAddress(chainId, newL2WBaseToken);
        store.reinitializeChain(chainId, newL2WBaseToken);
        vm.stopPrank();

        address storedAddress = store.l2WBaseTokenAddress(chainId);
        assertEq(storedAddress, newL2WBaseToken, "L2 WBaseToken address should be updated correctly");
    }

    function testReinitializeChainRevertsZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        store.reinitializeChain(chainId, address(0));
        vm.stopPrank();
    }

    // setPendingAdmin Tests
    function testSetPendingAdmin() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit NewPendingAdmin(address(0), newPendingAdmin);
        store.setPendingAdmin(newPendingAdmin);
        vm.stopPrank();

        assertEq(store.pendingAdmin(), newPendingAdmin, "Pending admin should be set correctly");
    }

    function testSetPendingAdminByAdmin() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit NewPendingAdmin(address(0), newPendingAdmin);
        store.setPendingAdmin(newPendingAdmin);
        vm.stopPrank();

        assertEq(store.pendingAdmin(), newPendingAdmin, "Pending admin should be set correctly by admin");
    }

    function testSetPendingAdminRevertsZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        store.setPendingAdmin(address(0));
        vm.stopPrank();
    }

    function testSetPendingAdminUnauthorized() public {
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, other));
        store.setPendingAdmin(newPendingAdmin);
        vm.stopPrank();
    }

    // acceptAdmin Tests
    function testAcceptAdmin() public {
        // Set pending admin
        vm.startPrank(owner);
        store.setPendingAdmin(newAdmin);
        vm.stopPrank();

        // Accept admin by newAdmin
        vm.startPrank(newAdmin);
        vm.expectEmit(true, true, false, true);
        emit NewPendingAdmin(newAdmin, address(0));
        vm.expectEmit(true, true, false, true);
        emit NewAdmin(admin, newAdmin);
        store.acceptAdmin();
        vm.stopPrank();

        assertEq(store.admin(), newAdmin, "Admin should be updated correctly");
        assertEq(store.pendingAdmin(), address(0), "Pending admin should be cleared");
    }

    function testAcceptAdminRevertsIfNotPendingAdmin() public {
        // Set pending admin
        vm.startPrank(owner);
        store.setPendingAdmin(newAdmin);
        vm.stopPrank();

        // Attempt to accept by someone else
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, other));
        store.acceptAdmin();
        vm.stopPrank();
    }

    function testSetAndAcceptAdminFlow() public {
        // Set pending admin by admin
        vm.startPrank(admin);
        store.setPendingAdmin(newPendingAdmin);
        vm.stopPrank();

        // Accept admin by newPendingAdmin
        vm.startPrank(newPendingAdmin);
        store.acceptAdmin();
        vm.stopPrank();

        assertEq(store.admin(), newPendingAdmin, "Admin should be updated to newPendingAdmin");
        assertEq(store.pendingAdmin(), address(0), "Pending admin should be cleared after acceptance");
    }

    // Event Emission Tests
    function testInitializeChainEmitsEvent() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit NewWBaseTokenAddress(chainId, l2WBaseToken);
        store.initializeChain(chainId, l2WBaseToken);
        vm.stopPrank();
    }

    function testReinitializeChainEmitsEvent() public {
        vm.startPrank(owner);
        store.initializeChain(chainId, l2WBaseToken);
        vm.expectEmit(true, true, false, true);
        emit NewWBaseTokenAddress(chainId, newL2WBaseToken);
        store.reinitializeChain(chainId, newL2WBaseToken);
        vm.stopPrank();
    }

    function testSetPendingAdminEmitsEvent() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit NewPendingAdmin(address(0), newPendingAdmin);
        store.setPendingAdmin(newPendingAdmin);
        vm.stopPrank();
    }

    function testAcceptAdminEmitsEvents() public {
        // Set pending admin
        vm.startPrank(owner);
        store.setPendingAdmin(newAdmin);
        vm.stopPrank();

        // Expect both events when accepting admin
        vm.startPrank(newAdmin);
        vm.expectEmit(true, true, false, true);
        emit NewPendingAdmin(newAdmin, address(0));
        vm.expectEmit(true, true, false, true);
        emit NewAdmin(admin, newAdmin);
        store.acceptAdmin();
        vm.stopPrank();
    }

    // Edge Case Tests
    function testReinitializeChainMultipleTimes() public {
        vm.startPrank(owner);
        store.initializeChain(chainId, l2WBaseToken);
        store.reinitializeChain(chainId, newL2WBaseToken);
        store.reinitializeChain(chainId, l2WBaseToken);
        address stored = store.l2WBaseTokenAddress(chainId);
        assertEq(stored, l2WBaseToken, "Mapping should reflect the last set address");
        vm.stopPrank();
    }

    function testSetPendingAdminTwice() public {
        vm.startPrank(owner);
        store.setPendingAdmin(newPendingAdmin);
        store.setPendingAdmin(admin);
        assertEq(store.pendingAdmin(), admin, "Pending admin should be updated to the latest set value");
        vm.stopPrank();
    }

    function testAcceptAdminWhenPendingAdminIsZero() public {
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, other));
        store.acceptAdmin();
        vm.stopPrank();
    }
}
