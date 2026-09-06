// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultCoreUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {CoreDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {MAX_NUMBER_OF_ZK_CHAINS} from "contracts/common/Config.sol";

// These fixtures isolate ABI discovery from the behavior of the discovered contracts.
// Missing historical getters must revert rather than returning a mocked default.
contract DiscoveryFixtureV31 {
    function messageRoot() external view returns (address) {
        return address(this);
    }
    function l1CtmDeployer() external view returns (address) {
        return address(this);
    }
    function chainAssetHandler() external view returns (address) {
        return address(this);
    }
    function chainRegistrationSender() external view returns (address) {
        return address(this);
    }
    function assetRouter() external view returns (address) {
        return address(this);
    }
    function L1_NULLIFIER() external view returns (address) {
        return address(this);
    }
    function nativeTokenVault() external view returns (address) {
        return address(this);
    }
    function bridgedTokenBeacon() external pure returns (address) {
        return address(0);
    }
    function L1_WETH_TOKEN() external pure returns (address) {
        return address(0);
    }
    function ETH_TOKEN_ASSET_ID() external pure returns (bytes32) {
        return bytes32(0);
    }
    function owner() external view returns (address) {
        return address(this);
    }
    function admin() external view returns (address) {
        return address(this);
    }
}

contract DiscoveryFixturePreCenter is DiscoveryFixtureV31 {
    function l1InteropHandler() external view returns (address) {
        return address(this);
    }
}

contract DiscoveryFixtureCurrent is DiscoveryFixturePreCenter {
    function interopCenter() external view returns (address) {
        return address(this);
    }
}

contract CTMInteropDiscoveryHarness is DefaultCTMUpgrade {
    function discover(
        address _bridgehub,
        bool _preV32,
        bool _hasCenter
    ) external returns (CoreDeployedAddresses memory) {
        newConfig.hasL1InteropCenter = _hasCenter;
        _discoverCoreAddresses(_bridgehub, _preV32);
        return coreAddresses;
    }
}

contract CoreInteropDiscoveryHarness is DefaultCoreUpgrade {
    function discover(
        address _bridgehub,
        bool _preV32,
        bool _hasCenter
    ) external returns (CoreDeployedAddresses memory) {
        coreAddresses.bridgehub.proxies.bridgehub = _bridgehub;
        additionalConfig.hasPreV32IntrospectionOverride = true;
        additionalConfig.usePreV32IntrospectionOverride = _preV32;
        additionalConfig.hasL1InteropCenter = _hasCenter;
        setAddressesBasedOnBridgehub();
        return coreAddresses;
    }
}

contract L1InteropCenterDiscoveryTest is Test {
    CTMInteropDiscoveryHarness internal script;
    CoreInteropDiscoveryHarness internal coreScript;

    function setUp() public {
        script = new CTMInteropDiscoveryHarness();
        coreScript = new CoreInteropDiscoveryHarness();
    }

    function _proxy(address _implementation) private returns (address) {
        return address(new TransparentUpgradeableProxy(_implementation, makeAddr("proxyAdmin"), ""));
    }

    function test_v31_discoveryDoesNotCallEitherNewGetter() public {
        address bridgehub = _proxy(address(new DiscoveryFixtureV31()));
        CoreDeployedAddresses memory addresses = script.discover(bridgehub, true, false);
        assertEq(addresses.bridgehub.proxies.bridgehub, bridgehub);
        assertEq(addresses.bridgehub.proxies.interopCenter, address(0));
        assertEq(addresses.bridges.proxies.l1InteropHandler, address(0));
    }

    function test_v32AndV33_discoveryRetainsHandlerWithoutCenterGetter() public {
        address bridgehub = _proxy(address(new DiscoveryFixturePreCenter()));
        CoreDeployedAddresses memory addresses = script.discover(bridgehub, false, false);
        assertEq(addresses.bridgehub.proxies.bridgehub, bridgehub);
        assertEq(addresses.bridgehub.proxies.interopCenter, address(0));
        assertEq(addresses.bridges.proxies.l1InteropHandler, bridgehub);
    }

    function test_current_discoveryRetainsExistingCenter() public {
        address implementation = address(new DiscoveryFixtureCurrent());
        address bridgehub = _proxy(implementation);
        CoreDeployedAddresses memory addresses = script.discover(bridgehub, false, true);
        assertEq(addresses.bridgehub.proxies.interopCenter, bridgehub);
        assertEq(addresses.bridgehub.implementations.interopCenter, implementation);
        assertEq(addresses.bridges.proxies.l1InteropHandler, bridgehub);
    }

    function test_currentFlagOnHistoricalSource_revertsOnMissingGetter() public {
        address bridgehub = _proxy(address(new DiscoveryFixturePreCenter()));
        vm.expectRevert();
        script.discover(bridgehub, false, true);
    }

    function test_currentFlagRetainsRealCenterWithPreV32Introspection() public {
        L1Bridgehub bridgehub = L1Bridgehub(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1Bridgehub(address(this), MAX_NUMBER_OF_ZK_CHAINS)),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1Bridgehub.initialize, (address(this)))
                )
            )
        );
        L1InteropCenter implementation = new L1InteropCenter(IL1Bridgehub(address(bridgehub)));
        L1InteropCenter center = L1InteropCenter(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1InteropCenter.initialize, (address(this)))
                )
            )
        );
        // Unrelated core contracts share an ABI fixture; registry and center state use real proxies.
        address other = _proxy(address(new DiscoveryFixturePreCenter()));
        bridgehub.setAddresses(other, ICTMDeploymentTracker(other), IMessageRootBase(other), other, other);
        bridgehub.setInteropCenter(address(center));
        center.pause();
        address pendingOwner = makeAddr("pendingOwner");
        center.transferOwnership(pendingOwner);

        CoreDeployedAddresses memory coreAddresses = coreScript.discover(address(bridgehub), true, true);
        CoreDeployedAddresses memory ctmAddresses = script.discover(address(bridgehub), true, true);
        assertEq(coreAddresses.bridgehub.proxies.interopCenter, address(center));
        assertEq(ctmAddresses.bridgehub.proxies.interopCenter, address(center));
        assertEq(coreAddresses.bridgehub.implementations.interopCenter, address(implementation));
        assertEq(ctmAddresses.bridgehub.implementations.interopCenter, address(implementation));
        assertEq(coreAddresses.bridges.proxies.l1InteropHandler, other);
        assertEq(ctmAddresses.bridges.proxies.l1InteropHandler, other);
        assertEq(center.owner(), address(this));
        assertEq(center.pendingOwner(), pendingOwner);
        assertTrue(center.paused());
        assertEq(bridgehub.interopCenter(), address(center));
    }

    function test_upgradeInputsRequireExplicitCenterFlag() public {
        string memory path = "script-out/l1-interop-center-missing-flag-test.toml";
        vm.writeFile(path, "pre_v32_introspection = false\n");
        vm.expectRevert("Set has_l1_interop_center explicitly");
        coreScript.initializeConfigWithArgs(address(0), bytes32(0), path);
        vm.expectRevert("Set has_l1_interop_center explicitly");
        script.initializeWithArgs(
            address(0),
            address(0),
            address(0),
            bytes32(0),
            string.concat("/", path),
            "",
            address(0),
            bytes32(0)
        );
        vm.removeFile(path);
    }
}
