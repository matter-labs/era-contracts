// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {MockContract} from "contracts/dev-contracts/MockContract.sol";
import {L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AddressHasNoCode, Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @dev `L2ComplexUpgrader` gates on `msg.sender` only and never inspects its own address, so it is
/// exercised as a plain unit test rather than through an L2 harness. The force-deployment paths that
/// `forceDeployAndUpgrade*` delegate into are covered in `L2GenesisForceDeploymentHelper.t.sol`.
contract L2ComplexUpgraderTest is Test {
    L2ComplexUpgrader internal upgrader;
    MockContract internal dummyUpgrade;

    function setUp() public {
        upgrader = new L2ComplexUpgrader();
        dummyUpgrade = new MockContract();
    }

    function test_RevertWhen_NonForceDeployerCallsUpgrade() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        upgrader.upgrade(address(dummyUpgrade), hex"deadbeef");
    }

    function test_RevertWhen_TargetHasNoCode() public {
        address emptyTarget = makeAddr("emptyTarget");

        vm.expectRevert(abi.encodeWithSelector(AddressHasNoCode.selector, emptyTarget));
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        upgrader.upgrade(emptyTarget, hex"deadbeef");
    }

    /// @dev The target is delegatecalled, so the event is emitted from the upgrader's own address.
    function test_SuccessfulUpgrade() public {
        vm.expectEmit(true, true, false, true, address(upgrader));
        emit MockContract.Called(0, hex"deadbeef");

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        upgrader.upgrade(address(dummyUpgrade), hex"deadbeef");
    }

    /// @dev Value passed to `upgrade` must reach the delegatecalled target as `msg.value`.
    function test_SuccessfulUpgrade_ForwardsValue() public {
        uint256 value = 1 ether;
        vm.deal(L2_FORCE_DEPLOYER_ADDR, value);

        vm.expectEmit(true, true, false, true, address(upgrader));
        emit MockContract.Called(value, hex"deadbeef");

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        upgrader.upgrade{value: value}(address(dummyUpgrade), hex"deadbeef");
    }
}
