// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract ChainTypeManagerGettersAndSettersTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    // Test getZKChain - delegates to bridgehub
    function test_getZKChain() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        // Mock the bridgehub's getZKChain to return the created chain address
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainAddress)
        );

        address result = chainContractAddress.getZKChain(chainId);
        assertEq(result, chainAddress, "getZKChain should return the chain address from bridgehub");
    }

    // Test getZKChain returns zero address for non-existent chain
    function test_getZKChainReturnsZeroForNonExistentChain() public {
        uint256 nonExistentChainId = 999999;

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, nonExistentChainId),
            abi.encode(address(0))
        );

        address result = chainContractAddress.getZKChain(nonExistentChainId);
        assertEq(result, address(0), "getZKChain should return zero for non-existent chain");
    }

    // Test getZKChainLegacy - returns from deprecated map
    function test_getZKChainLegacy() public {
        // Since the deprecated map is not populated in normal flow,
        // this should return address(0)
        address result = chainContractAddress.getZKChainLegacy(chainId);
        assertEq(result, address(0), "getZKChainLegacy should return zero for chains not in legacy map");
    }

    // Test getChainAdmin
    function test_getChainAdmin() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        _mockGetZKChainFromBridgehub(chainAddress);

        address chainAdmin = chainContractAddress.getChainAdmin(chainId);
        // newChainAdmin is set in createNewChain
        assertEq(chainAdmin, newChainAdmin, "getChainAdmin should return the chain admin");
    }

    // Test getHyperchain (legacy function)
    function test_getHyperchain() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        // Mock the bridgehub's getZKChain
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainAddress)
        );

        // getHyperchain first checks legacy map, then falls back to getZKChain
        address result = chainContractAddress.getHyperchain(chainId);
        assertEq(result, chainAddress, "getHyperchain should return chain address");
    }

    // Test setLegacyValidatorTimelock
    function test_setLegacyValidatorTimelock() public {
        address newLegacyTimelock = makeAddr("newLegacyTimelock");

        chainContractAddress.setLegacyValidatorTimelock(newLegacyTimelock);

        address result = chainContractAddress.validatorTimelock();
        assertEq(result, newLegacyTimelock, "Legacy validator timelock should be updated");
    }

    // Test setLegacyValidatorTimelock emits event
    function test_setLegacyValidatorTimelockEmitsEvent() public {
        address newLegacyTimelock = makeAddr("newLegacyTimelock");

        vm.expectEmit(true, true, true, true);
        emit NewValidatorTimelock(address(0), newLegacyTimelock);

        chainContractAddress.setLegacyValidatorTimelock(newLegacyTimelock);
    }

    // Test setLegacyValidatorTimelock reverts when not owner
    function test_RevertWhen_setLegacyValidatorTimelockNotOwner() public {
        vm.stopPrank();

        address notOwner = makeAddr("notOwner");
        address newLegacyTimelock = makeAddr("newLegacyTimelock");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setLegacyValidatorTimelock(newLegacyTimelock);
    }

    // Test setServerNotifier
    function test_setServerNotifier() public {
        address newServerNotifier = makeAddr("newServerNotifier");

        chainContractAddress.setServerNotifier(newServerNotifier);

        address result = chainContractAddress.serverNotifierAddress();
        assertEq(result, newServerNotifier, "Server notifier should be updated");
    }

    // Test setServerNotifier emits event
    function test_setServerNotifierEmitsEvent() public {
        address newServerNotifier = makeAddr("newServerNotifier");

        vm.expectEmit(true, true, true, true);
        emit NewServerNotifier(serverNotifier, newServerNotifier);

        chainContractAddress.setServerNotifier(newServerNotifier);
    }

    // Test setServerNotifier by admin (not just owner)
    function test_setServerNotifierByAdmin() public {
        // First set an admin
        address ctmAdmin = makeAddr("ctmAdmin");
        chainContractAddress.setPendingAdmin(ctmAdmin);

        vm.stopPrank();
        vm.prank(ctmAdmin);
        chainContractAddress.acceptAdmin();

        // Now admin can call setServerNotifier
        address newServerNotifier = makeAddr("newServerNotifier");

        vm.prank(ctmAdmin);
        chainContractAddress.setServerNotifier(newServerNotifier);

        address result = chainContractAddress.serverNotifierAddress();
        assertEq(result, newServerNotifier, "Server notifier should be updated by admin");
    }

    // Test setServerNotifier reverts when not owner or admin
    function test_RevertWhen_setServerNotifierNotOwnerOrAdmin() public {
        vm.stopPrank();

        address notOwnerOrAdmin = makeAddr("notOwnerOrAdmin");
        address newServerNotifier = makeAddr("newServerNotifier");

        vm.prank(notOwnerOrAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notOwnerOrAdmin));
        chainContractAddress.setServerNotifier(newServerNotifier);
    }

    // Test getSemverProtocolVersion
    function test_getSemverProtocolVersion() public view {
        (uint32 major, uint32 minor, uint32 patch) = chainContractAddress.getSemverProtocolVersion();
        // Protocol version is set to 0 in initialize, which unpacks to (0, 0, 0)
        assertEq(major, 0, "Major version should be 0");
        assertEq(minor, 0, "Minor version should be 0");
        assertEq(patch, 0, "Patch version should be 0");
    }

    // Test protocolVersionIsActive
    function test_protocolVersionIsActive() public view {
        // Protocol version 0 was set with deadline type(uint256).max
        bool isActive = chainContractAddress.protocolVersionIsActive(0);
        assertTrue(isActive, "Protocol version 0 should be active");
    }

    // Test protocolVersionIsActive for inactive version
    function test_protocolVersionIsInactive() public view {
        // Protocol version 999 was never set, so deadline is 0
        bool isActive = chainContractAddress.protocolVersionIsActive(999);
        assertFalse(isActive, "Unset protocol version should be inactive");
    }

    // Test validatorTimelock (deprecated getter)
    function test_validatorTimelock() public view {
        // Initially the deprecated validator timelock is address(0)
        address result = chainContractAddress.validatorTimelock();
        assertEq(result, address(0), "Deprecated validator timelock should be zero initially");
    }

    // Events
    event NewValidatorTimelock(address indexed oldValidatorTimelock, address indexed newValidatorTimelock);
    event NewServerNotifier(address indexed oldServerNotifier, address indexed newServerNotifier);
}
