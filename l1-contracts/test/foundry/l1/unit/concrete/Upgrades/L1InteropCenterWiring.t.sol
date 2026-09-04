// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {CoreUpgrade_v34} from "deploy-scripts/upgrade/v34/CoreUpgrade_v34.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

contract L1InteropCenterWiringHarness is CoreUpgrade_v34 {
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
    function wiring() external returns (Call[] memory) {
        return _buildL1InteropCenterWiringCalls();
    }
}

contract L1InteropCenterWiringTest is Test {
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
    }

    function _execute(Call[] memory _calls) private {
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
        Call[] memory calls = script.wiring();
        assertEq(calls.length, 2);
        _execute(calls);
        assertEq(center.owner(), address(this));
        assertEq(center.pendingOwner(), address(0));
        assertEq(bridgehub.interopCenter(), address(center));
    }

    function test_existingProxy_upgradesAndPreservesState() public {
        vm.prank(makeAddr("deployer"));
        center.pause();
        L1InteropCenter implementation = new L1InteropCenter(IL1Bridgehub(address(bridgehub)));
        script.configure(address(bridgehub), address(center), address(implementation), address(proxyAdmin), false);
        _execute(script.wiring());
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(center))),
            address(implementation)
        );
        assertEq(center.owner(), makeAddr("deployer"));
        assertTrue(center.paused());
        assertEq(bridgehub.interopCenter(), address(center));
    }

    function test_missingProxy_reverts() public {
        script.configure(address(bridgehub), address(0), address(0), address(proxyAdmin), true);
        vm.expectRevert("L1InteropCenter proxy not deployed");
        script.wiring();
    }
}
