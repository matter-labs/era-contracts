// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {CoreUpgrade_v31} from "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {InteropCenterNotPaused} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

contract L1InteropCenterWiringHarness is CoreUpgrade_v31 {
    function configure(
        address _bridgehub,
        address _center,
        address _implementation,
        address _proxyAdmin,
        bool _newProxy
    ) external {
        coreAddresses.bridgehub.proxies.bridgehub = _bridgehub;
        coreAddresses.bridgehub.proxies.interopCenter = _center;
        coreAddresses.bridgehub.implementations.interopCenter = _implementation;
        coreAddresses.shared.transparentProxyAdmin = _proxyAdmin;
        deployedL1InteropCenter = _newProxy;
    }
    function configureOtherProxies(address _proxy, address _implementation) external {
        coreAddresses.bridgehub.implementations.bridgehub = _implementation;
        coreAddresses.bridges.proxies.l1Nullifier = _proxy;
        coreAddresses.bridges.implementations.l1Nullifier = _implementation;
        coreAddresses.bridges.proxies.l1AssetRouter = _proxy;
        coreAddresses.bridges.implementations.l1AssetRouter = _implementation;
        coreAddresses.bridges.proxies.l1NativeTokenVault = _proxy;
        coreAddresses.bridges.implementations.l1NativeTokenVault = _implementation;
        coreAddresses.bridgehub.proxies.messageRoot = _proxy;
        coreAddresses.bridgehub.implementations.messageRoot = _implementation;
        coreAddresses.bridgehub.proxies.ctmDeploymentTracker = _proxy;
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = _implementation;
        coreAddresses.bridgehub.proxies.chainAssetHandler = _proxy;
        coreAddresses.bridgehub.implementations.chainAssetHandler = _implementation;
    }
    function wiring() external returns (Call[] memory) {
        return _buildL1InteropCenterWiringCalls();
    }
}

contract L1InteropCenterWiringTest is Test {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Upgraded(address indexed implementation);
    L1InteropCenterWiringHarness internal script;
    L1Bridgehub internal bridgehub;
    L1InteropCenter internal center;
    ProxyAdmin internal proxyAdmin;

    function setUp() public {
        proxyAdmin = new ProxyAdmin();
        L1Bridgehub implementation = new L1Bridgehub(address(this), 100);
        bridgehub = L1Bridgehub(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(proxyAdmin),
                    abi.encodeCall(L1Bridgehub.initialize, (address(this)))
                )
            )
        );
        L1InteropCenter centerImpl = new L1InteropCenter(IL1Bridgehub(address(bridgehub)));
        center = L1InteropCenter(
            address(
                new TransparentUpgradeableProxy(
                    address(centerImpl),
                    address(proxyAdmin),
                    abi.encodeCall(L1InteropCenter.initialize, (makeAddr("deployer")))
                )
            )
        );
        script = new L1InteropCenterWiringHarness();
        // Unrelated default upgrades share a real proxy fixture; center and Bridgehub state are isolated from it.
        address otherProxy = address(new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), ""));
        script.configureOtherProxies(otherProxy, address(implementation));
    }

    function executeCalls(Call[] calldata _calls) external {
        for (uint256 i = 0; i < _calls.length; ++i) {
            (bool success, bytes memory reason) = _calls[i].target.call(_calls[i].data);
            if (!success) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    function test_newProxy_acceptsOwnershipThenRegisters() public {
        vm.prank(makeAddr("deployer"));
        center.transferOwnership(address(this));
        script.configure(address(bridgehub), address(center), address(0), address(proxyAdmin), true);
        address implementation = proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(center)));
        this.executeCalls(script.prepareUpgradeProxiesCalls());
        assertEq(proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(center))), implementation);
        assertEq(center.owner(), makeAddr("deployer"));
        assertEq(center.pendingOwner(), address(this));
        assertEq(bridgehub.interopCenter(), address(0));
        Call[] memory calls = script.wiring();
        assertEq(calls.length, 2);
        this.executeCalls(calls);
        assertEq(center.owner(), address(this));
        assertEq(center.pendingOwner(), address(0));
        assertEq(bridgehub.interopCenter(), address(center));
        assertFalse(center.paused());
    }

    function test_newProxy_rejectsLatePauseAndAllowsExplicitRecovery(bool _pauseCenter) public {
        vm.prank(makeAddr("deployer"));
        center.transferOwnership(address(this));
        script.configure(address(bridgehub), address(center), address(0), address(proxyAdmin), true);
        Call[] memory calls = script.wiring();
        bridgehub.pause();

        vm.expectRevert(InteropCenterNotPaused.selector);
        this.executeCalls(calls);
        assertEq(bridgehub.interopCenter(), address(0));
        assertEq(center.owner(), makeAddr("deployer"));
        assertEq(center.pendingOwner(), address(this));
        assertTrue(bridgehub.paused());

        if (_pauseCenter) {
            vm.prank(makeAddr("deployer"));
            center.pause();
        } else {
            bridgehub.unpause();
        }
        vm.expectEmit(true, true, false, true, address(center));
        emit OwnershipTransferred(makeAddr("deployer"), address(this));
        vm.expectEmit(true, false, false, true, address(bridgehub));
        emit IBridgehubBase.InteropCenterSet(address(center));
        this.executeCalls(calls);
        assertEq(center.owner(), address(this));
        assertEq(bridgehub.interopCenter(), address(center));
        assertEq(center.paused(), _pauseCenter);
        assertEq(bridgehub.paused(), _pauseCenter);
    }

    function test_existingProxy_upgradesAndPreservesState(bool _paused) public {
        bridgehub.setInteropCenter(address(center));
        bridgehub.pause();
        if (_paused) {
            vm.prank(makeAddr("deployer"));
            center.pause();
        }
        address pendingOwner = makeAddr("pendingOwner");
        vm.prank(makeAddr("deployer"));
        center.transferOwnership(pendingOwner);
        L1InteropCenter implementation = new L1InteropCenter(IL1Bridgehub(address(bridgehub)));
        script.configure(address(bridgehub), address(center), address(implementation), address(proxyAdmin), false);
        Call[] memory calls = script.prepareUpgradeProxiesCalls();
        vm.expectEmit(true, false, false, true, address(center));
        emit Upgraded(address(implementation));
        this.executeCalls(calls);
        assertEq(script.wiring().length, 0);
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(center))),
            address(implementation)
        );
        assertEq(center.owner(), makeAddr("deployer"));
        assertEq(center.pendingOwner(), pendingOwner);
        assertEq(center.paused(), _paused);
        assertTrue(bridgehub.paused());
        assertEq(bridgehub.interopCenter(), address(center));
    }

    function test_missingProxy_reverts(bool _newProxy) public {
        script.configure(address(bridgehub), address(0), address(0), address(proxyAdmin), _newProxy);
        vm.expectRevert("L1InteropCenter proxy not deployed");
        script.wiring();
        vm.expectRevert("L1InteropCenter proxy not deployed");
        script.prepareUpgradeProxiesCalls();
    }
}
