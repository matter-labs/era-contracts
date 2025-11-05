// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {SystemContractProxy} from "contracts/l2-upgrades/SystemContractProxy.sol";
import {ISystemContractProxy} from "contracts/l2-upgrades/ISystemContractProxy.sol";
import {SystemContractProxyAdmin} from "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SystemContractProxyInitialized} from "contracts/common/L1ContractErrors.sol";

contract MockImplementation {
    event Delegated(bytes4 indexed sig, address indexed arg);

    // Helpers to verify delegation of admin() / implementation() calls by non-admins.
    function admin() external pure returns (address) {
        return address(0x00000000000000000000000000000000000A11cE);
    }

    function implementation() external pure returns (address) {
        return address(0x000000000000000000000000000000000000bEEF);
    }

    // Admin-method-shaped functions so that when non-admin calls hit the proxy,
    // they delegate here (not actually performing admin actions).
    function changeAdmin(address newAdmin) external {
        emit Delegated(msg.sig, newAdmin);
    }

    function upgradeTo(address newImpl) external {
        emit Delegated(msg.sig, newImpl);
    }

    function upgradeToAndCall(address newImpl, bytes calldata /*data*/) external {
        emit Delegated(msg.sig, newImpl);
    }

    // Same for the special forceInitAdmin selector — non-upgrader should delegate.
    function forceInitAdmin(address who) external {
        emit Delegated(msg.sig, who);
    }

    // A simple passthrough to show "normal" delegation also works.
    function echo(uint256 x) external pure returns (uint256) {
        return x + 1;
    }
}

contract SystemContractProxyTest is Test {
    // ERC1967 slots (from OpenZeppelin):
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal owner; // Owner of SystemContractProxyAdmin
    address internal newAdmin; // New proxy admin set later
    address internal user; // Non-admin user

    address internal proxy; // The etched SystemContractProxy
    address internal proxyAdmin; // The etched SystemContractProxyAdmin

    MockImplementation internal impl1;
    MockImplementation internal impl2;

    function setUp() public {
        owner = makeAddr("owner");
        newAdmin = makeAddr("newAdmin");
        user = makeAddr("user");

        proxy = makeAddr("proxy");
        proxyAdmin = makeAddr("proxyAdmin");

        // 1) Etch the proxy + proxy admin runtime code (no constructors run)
        vm.etch(proxy, type(SystemContractProxy).runtimeCode);
        vm.etch(proxyAdmin, type(SystemContractProxyAdmin).runtimeCode);

        // 2) Initialize the ProxyAdmin ownership (initializer pattern)
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        SystemContractProxyAdmin(proxyAdmin).forceSetOwner(owner);
        // Sanity: owner set
        assertEq(SystemContractProxyAdmin(proxyAdmin).owner(), owner, "ProxyAdmin owner mismatch");

        // 3) Force-initialize the proxy admin via the special path guarded by L2_COMPLEX_UPGRADER_ADDR
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        ISystemContractProxy(proxy).forceInitAdmin(proxyAdmin);

        // Sanity: proxy admin slot now set to proxyAdmin
        assertEq(_readAdmin(proxy), proxyAdmin, "Proxy admin should be initialized to ProxyAdmin");

        // 4) Deploy a first implementation normally (constructors allowed for non-proxy contracts)
        impl1 = new MockImplementation();

        // 5) Upgrade proxy to impl1 via ProxyAdmin.owner
        vm.prank(owner);
        SystemContractProxyAdmin(proxyAdmin).upgrade(ITransparentUpgradeableProxy(payable(proxy)), address(impl1));

        assertEq(_readImplementation(proxy), address(impl1), "impl1 should be active");
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────────────────

    function _readImplementation(address p) internal view returns (address) {
        return address(uint160(uint256(vm.load(p, _IMPLEMENTATION_SLOT))));
    }

    function _readAdmin(address p) internal view returns (address) {
        return address(uint160(uint256(vm.load(p, _ADMIN_SLOT))));
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Tests
    // ──────────────────────────────────────────────────────────────────────────────

    function test_NonAdmin_AdminSelectorsAreDelegated() public {
        // Non-admin calls should delegate admin() to the implementation (returning impl sentinel)
        vm.prank(user);
        address apparentAdmin = ITransparentUpgradeableProxy(payable(proxy)).admin();
        assertEq(
            apparentAdmin,
            address(0x00000000000000000000000000000000000A11cE),
            "admin() should be delegated for non-admin callers"
        );

        // Non-admin calls should delegate implementation() to the implementation (returning impl sentinel)
        vm.prank(user);
        address apparentImpl = ITransparentUpgradeableProxy(payable(proxy)).implementation();
        assertEq(
            apparentImpl,
            address(0x000000000000000000000000000000000000bEEF),
            "implementation() should be delegated for non-admin callers"
        );
    }

    function test_NonAdmin_UpgradeAndChangeAdminSelectorsDelegate_NoStateChange() public {
        // Record current impl
        address beforeImpl = _readImplementation(proxy);

        // Expect delegation events from the proxy address (delegatecall context)
        vm.expectEmit(true, true, true, true, proxy);
        emit MockImplementation.Delegated(ITransparentUpgradeableProxy.upgradeTo.selector, address(0x1234));

        vm.prank(user);
        ITransparentUpgradeableProxy(payable(proxy)).upgradeTo(address(0x1234));
        // Should NOT have changed the implementation (since it was delegated to impl)
        assertEq(_readImplementation(proxy), beforeImpl, "impl should not change when non-admin calls upgradeTo");

        vm.expectEmit(true, true, true, true, proxy);
        emit MockImplementation.Delegated(ITransparentUpgradeableProxy.changeAdmin.selector, address(0xDEAD));

        vm.prank(user);
        ITransparentUpgradeableProxy(payable(proxy)).changeAdmin(address(0xDEAD));
        // Should NOT have changed the admin
        assertEq(_readAdmin(proxy), proxyAdmin, "admin should not change when non-admin calls changeAdmin");
    }

    function test_ProxyAdminOwner_CanChangeProxyAdmin_And_NewAdminCanUpgrade() public {
        // Change proxy admin from ProxyAdmin -> newAdmin using ProxyAdmin (as owner)
        vm.prank(owner);
        SystemContractProxyAdmin(proxyAdmin).changeProxyAdmin(ITransparentUpgradeableProxy(payable(proxy)), newAdmin);
        assertEq(_readAdmin(proxy), newAdmin, "proxy admin should be changed to newAdmin");

        // Try to upgrade again via the *old* ProxyAdmin (should now DELEGATE, not upgrade)
        address beforeImpl = _readImplementation(proxy);
        impl2 = new MockImplementation();

        vm.prank(owner);
        SystemContractProxyAdmin(proxyAdmin).upgrade(ITransparentUpgradeableProxy(payable(proxy)), address(impl2));

        // Implementation must remain the same (old ProxyAdmin is no longer admin)
        assertEq(_readImplementation(proxy), beforeImpl, "old ProxyAdmin should no longer be able to upgrade");

        // Now the new admin (EOA) calls upgradeTo directly on the proxy: this should perform the real upgrade.
        vm.prank(newAdmin);
        ITransparentUpgradeableProxy(payable(proxy)).upgradeTo(address(impl2));
        assertEq(_readImplementation(proxy), address(impl2), "newAdmin should successfully upgrade the proxy");
    }

    function test_ForceInitAdmin_Reverts_AfterInitialized() public {
        // Admin already initialized in setUp(); calling again as the upgrader should revert.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(SystemContractProxyInitialized.selector));
        ISystemContractProxy(proxy).forceInitAdmin(makeAddr("irrelevant"));
    }

    function test_ForceInitAdmin_FromNonUpgrader_DelegatesToImplementation() public {
        // Non-upgrader caller should delegate to implementation's forceInitAdmin
        vm.expectEmit(true, true, true, true, proxy);
        emit MockImplementation.Delegated(ISystemContractProxy.forceInitAdmin.selector, address(0xCAFE));

        vm.prank(user);
        ISystemContractProxy(proxy).forceInitAdmin(address(0xCAFE));
    }

    function test_NormalDelegation_FallbackCallsReachImplementation() public {
        // Call an arbitrary non-admin function to ensure normal fallback delegation is intact.
        (bool ok, bytes memory ret) = proxy.call(abi.encodeWithSignature("echo(uint256)", 41));
        assertTrue(ok, "echo call via proxy should succeed");
        uint256 result = abi.decode(ret, (uint256));
        assertEq(result, 42, "echo should return x+1");
    }

    function test_AdminViewFns_ReturnRealValues_WhenCalledAsAdmin() public {
        // When msg.sender == admin, admin() / implementation() should be served by the proxy itself.
        address admin = _readAdmin(proxy);
        vm.prank(admin);
        address reportedAdmin = ITransparentUpgradeableProxy(payable(proxy)).admin();
        assertEq(reportedAdmin, admin, "as admin, admin() should return real admin");

        vm.prank(admin);
        address reportedImpl = ITransparentUpgradeableProxy(payable(proxy)).implementation();
        assertEq(
            reportedImpl,
            _readImplementation(proxy),
            "as admin, implementation() should return real implementation"
        );
    }
}
