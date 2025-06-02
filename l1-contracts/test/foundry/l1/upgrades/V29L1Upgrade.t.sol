// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {V29L1Upgrade} from "contracts/upgrades/V29L1Upgrade.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH} from "contracts/common/Config.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyV29L1Upgrade is V29L1Upgrade, BaseUpgradeUtils {
    function setValidator(address _validator, bool _isActive) public {
        s.validators[_validator] = _isActive;
    }

    function getPrecommitmentForTheLatestBatch() public view returns (bytes32) {
        return s.precommitmentForTheLatestBatch;
    }

    function getValidator(address _validator) public view returns (bool) {
        return s.validators[_validator];
    }
}

contract V29L1UpgradeTest is BaseUpgrade {
    DummyV29L1Upgrade internal upgrade;
    address internal oldValidatorTimelock1;
    address internal oldValidatorTimelock2;
    address internal newValidatorTimelock;

    function setUp() public {
        oldValidatorTimelock1 = makeAddr("oldValidatorTimelock1");
        oldValidatorTimelock2 = makeAddr("oldValidatorTimelock2");
        newValidatorTimelock = makeAddr("newValidatorTimelock");

        // Deploy V29L1Upgrade
        upgrade = new DummyV29L1Upgrade();

        // Set initial validator states
        upgrade.setValidator(oldValidatorTimelock1, true);
        upgrade.setValidator(oldValidatorTimelock2, true);

        // Verify initial validator states
        assertTrue(upgrade.getValidator(oldValidatorTimelock1));
        assertTrue(upgrade.getValidator(oldValidatorTimelock2));

        _prepareEmptyProposedUpgrade();

        upgrade.setPriorityTxMaxGasLimit(1 ether);
        upgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_SuccessUpgrade() public {
        // Prepare upgrade parameters
        address[] memory oldValidatorTimelocks = new address[](2);
        oldValidatorTimelocks[0] = oldValidatorTimelock1;
        oldValidatorTimelocks[1] = oldValidatorTimelock2;

        V29L1Upgrade.V29UpgradeParams memory params = V29L1Upgrade.V29UpgradeParams({
            oldValidatorTimelocks: oldValidatorTimelocks,
            newValidatorTimelock: newValidatorTimelock
        });

        bytes memory postUpgradeCalldata = abi.encode(params);
        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectEmit(true, true, true, true);
        emit BaseZkSyncUpgrade.NewProtocolVersion(0, protocolVersion);
        // Expect events for each validator status update
        vm.expectEmit(true, true, true, true);
        emit IAdmin.ValidatorStatusUpdate(oldValidatorTimelock1, false);

        vm.expectEmit(true, true, true, true);
        emit IAdmin.ValidatorStatusUpdate(oldValidatorTimelock2, false);

        vm.expectEmit(true, true, true, true);
        emit IAdmin.ValidatorStatusUpdate(newValidatorTimelock, true);

        // Execute upgrade
        bytes32 result = upgrade.upgrade(proposedUpgrade);

        // Verify results
        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgrade.getPrecommitmentForTheLatestBatch(), DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH);

        // Verify validator status updates
        assertFalse(upgrade.getValidator(oldValidatorTimelock1));
        assertFalse(upgrade.getValidator(oldValidatorTimelock2));
        assertTrue(upgrade.getValidator(newValidatorTimelock));
    }
}
