// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DefaultCoreUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {DeployL1CoreContractsScript} from "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol";

contract InteropCenterUpgradeOutputHarness is DefaultCoreUpgrade {
    function writeOutput(address _center, address _implementation, bool _newProxy, string memory _path) external {
        coreAddresses.bridgehub.proxies.interopCenter = _center;
        coreAddresses.bridgehub.implementations.interopCenter = _implementation;
        deployedL1InteropCenter = _newProxy;
        saveOutput(_path);
    }
}

contract InteropCenterDeploymentOutputHarness is DeployL1CoreContractsScript {
    function writeOutput(address _center, address _implementation, string memory _path) external {
        coreAddresses.bridgehub.proxies.interopCenter = _center;
        coreAddresses.bridgehub.implementations.interopCenter = _implementation;
        saveOutput(_path);
    }
}

contract L1InteropCenterOutputTest is Test {
    address internal center = makeAddr("center");
    address internal implementation = makeAddr("implementation");

    function _assertCenterAddresses(string memory _output, string memory _prefix) private view {
        assertEq(vm.parseTomlAddress(_output, string.concat(_prefix, ".l1_interop_center_proxy_addr")), center);
        assertEq(
            vm.parseTomlAddress(_output, string.concat(_prefix, ".l1_interop_center_implementation_addr")),
            implementation
        );
    }

    function test_freshDeploymentOutputIncludesCenter() public {
        string memory path = "script-out/l1-interop-center-fresh-output-test.toml";
        InteropCenterDeploymentOutputHarness script = new InteropCenterDeploymentOutputHarness();
        script.writeOutput(center, implementation, path);
        _assertCenterAddresses(vm.readFile(path), ".deployed_addresses.bridgehub");
        vm.removeFile(path);
    }

    function _assertUpgradeOutput(bool _newProxy, string memory _path) private {
        InteropCenterUpgradeOutputHarness script = new InteropCenterUpgradeOutputHarness();
        script.writeOutput(center, implementation, _newProxy, _path);
        string memory output = vm.readFile(_path);
        _assertCenterAddresses(output, ".upgrade_addresses.bridgehub");
        assertEq(vm.parseTomlBool(output, ".upgrade_addresses.bridgehub.l1_interop_center_new_proxy"), _newProxy);
        vm.removeFile(_path);
    }

    function test_newProxyUpgradeOutputIncludesCenterProvenance() public {
        _assertUpgradeOutput(true, "script-out/l1-interop-center-new-output-test.toml");
    }

    function test_existingProxyUpgradeOutputIncludesCenterProvenance() public {
        _assertUpgradeOutput(false, "script-out/l1-interop-center-existing-output-test.toml");
    }
}
