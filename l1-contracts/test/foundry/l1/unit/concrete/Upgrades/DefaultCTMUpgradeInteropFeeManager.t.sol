// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";

contract DefaultCTMUpgradeInteropFeeManagerTest is Test {
    // Only `CTMUpgrade_v35` deploys the interop fee manager: a later upgrade of a CTM without one must fail
    // before deploying anything, rather than construct a CTM whose `L1_INTEROP_FEE_MANAGER` is zero.
    function test_deployNewCTMContracts_revertsWithoutInteropFeeManager() public {
        DefaultCTMUpgrade script = new DefaultCTMUpgrade();
        vm.expectRevert(bytes("CTM has no L1InteropFeeManager registered; it is expected from v35 on"));
        script.deployNewCTMContracts();
    }
}
