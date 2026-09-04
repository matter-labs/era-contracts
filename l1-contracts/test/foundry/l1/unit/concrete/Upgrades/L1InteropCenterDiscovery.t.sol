// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {CoreDeployedAddresses} from "deploy-scripts/utils/Types.sol";

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

contract L1InteropCenterDiscoveryTest is Test {
    CTMInteropDiscoveryHarness internal script;

    function setUp() public {
        script = new CTMInteropDiscoveryHarness();
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
}
