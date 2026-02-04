// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeableBeaconDeployer} from "contracts/bridge/UpgradeableBeaconDeployer.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Unit tests for UpgradeableBeaconDeployer
contract UpgradeableBeaconDeployerTest is Test {
    UpgradeableBeaconDeployer internal deployer;

    function setUp() public {
        deployer = new UpgradeableBeaconDeployer();
    }

    function test_deployUpgradeableBeacon_returnsNonZeroAddress() public {
        address owner = makeAddr("owner");
        address beacon = deployer.deployUpgradeableBeacon(owner);

        assertTrue(beacon != address(0), "Beacon address should be non-zero");
    }

    function test_deployUpgradeableBeacon_transfersOwnership() public {
        address owner = makeAddr("owner");
        address beaconAddress = deployer.deployUpgradeableBeacon(owner);

        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);
        assertEq(beacon.owner(), owner, "Beacon owner should be the specified owner");
    }

    function test_deployUpgradeableBeacon_setsImplementation() public {
        address owner = makeAddr("owner");
        address beaconAddress = deployer.deployUpgradeableBeacon(owner);

        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);
        address implementation = beacon.implementation();

        assertTrue(implementation != address(0), "Implementation should be non-zero");
        assertTrue(implementation.code.length > 0, "Implementation should have code");
    }

    function testFuzz_deployUpgradeableBeacon_ownershipTransfer(address owner) public {
        vm.assume(owner != address(0));

        address beaconAddress = deployer.deployUpgradeableBeacon(owner);
        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);

        assertEq(beacon.owner(), owner);
    }
}
