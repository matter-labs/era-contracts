// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2ProxyAdminDeployer} from "contracts/governance/L2ProxyAdminDeployer.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

/// @notice Unit tests for L2ProxyAdminDeployer
contract L2ProxyAdminDeployerTest is Test {
    address internal aliasedGovernance;

    function setUp() public {
        aliasedGovernance = makeAddr("aliasedGovernance");
    }

    // ============ Constructor Tests ============

    function test_constructor_deploysProxyAdmin() public {
        L2ProxyAdminDeployer deployer = new L2ProxyAdminDeployer(aliasedGovernance);

        address proxyAdminAddress = deployer.PROXY_ADMIN_ADDRESS();
        assertTrue(proxyAdminAddress != address(0), "ProxyAdmin should be deployed");

        // Verify it's a ProxyAdmin by checking the owner
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);
        assertEq(proxyAdmin.owner(), aliasedGovernance, "ProxyAdmin owner should be aliased governance");
    }

    function test_constructor_transfersOwnershipToAliasedGovernance() public {
        L2ProxyAdminDeployer deployer = new L2ProxyAdminDeployer(aliasedGovernance);

        ProxyAdmin proxyAdmin = ProxyAdmin(deployer.PROXY_ADMIN_ADDRESS());
        assertEq(proxyAdmin.owner(), aliasedGovernance);
    }

    function testFuzz_constructor_deterministicAddress(address governance) public {
        vm.assume(governance != address(0));

        // Deploy two deployers with same governance - they should deploy ProxyAdmins at different addresses
        // because the deployers themselves are at different addresses
        L2ProxyAdminDeployer deployer1 = new L2ProxyAdminDeployer(governance);
        L2ProxyAdminDeployer deployer2 = new L2ProxyAdminDeployer(governance);

        // Since CREATE2 is used with salt=0, the ProxyAdmin address depends on the deployer address
        // Different deployer addresses -> different ProxyAdmin addresses
        assertTrue(
            deployer1.PROXY_ADMIN_ADDRESS() != deployer2.PROXY_ADMIN_ADDRESS(),
            "Different deployers should create different ProxyAdmins"
        );
    }

    function testFuzz_constructor_ownershipTransfer(address governance) public {
        vm.assume(governance != address(0));

        L2ProxyAdminDeployer deployer = new L2ProxyAdminDeployer(governance);
        ProxyAdmin proxyAdmin = ProxyAdmin(deployer.PROXY_ADMIN_ADDRESS());

        assertEq(proxyAdmin.owner(), governance, "Owner should match governance address");
    }
}
