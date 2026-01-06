// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {MockContract} from "contracts/dev-contracts/MockContract.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

contract L2ComplexUpgraderTest is Test {
    MockContract public dummyUpgrade;

    function setUp() public {
        bytes memory code = Utils.readZKFoundryBytecodeL1("L2ComplexUpgrader.sol", "L2ComplexUpgrader");
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, code);
        dummyUpgrade = new MockContract();
    }

    function test_RevertWhen_NonForceDeployerCallsUpgrade() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(address(dummyUpgrade), hex"deadbeef");
    }

    function test_SuccessfulUpgrade() public {
        vm.expectEmit(true, true, false, true, L2_COMPLEX_UPGRADER_ADDR);
        emit MockContract.Called(0, hex"deadbeef");

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(address(dummyUpgrade), hex"deadbeef");
    }
}
