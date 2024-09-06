// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Utils} from "../Utils/Utils.sol";

import {GovernanceTest} from "./_Governance_Shared.t.sol";

import {IGovernance} from "contracts/governance/IGovernance.sol";

contract SelfUpgradesTest is GovernanceTest {
    event ChangeSecurityCouncil(address _securityCouncilBefore, address _securityCouncilAfter);

    event ChangeMinDelay(uint256 _delayBefore, uint256 _delayAfter);

    function test_UpgradeDelay() public {
        vm.startPrank(owner);
        uint256 delayBefore = governance.minDelay();
        uint256 newDelay = 100000;
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(governance),
            0,
            abi.encodeCall(IGovernance.updateDelay, (newDelay))
        );

        governance.scheduleTransparent(op, 0);
        // Check event
        vm.expectEmit(false, false, false, true);
        emit ChangeMinDelay(delayBefore, newDelay);
        governance.execute(op);
        uint256 delayAfter = governance.minDelay();
        assertTrue(delayBefore != delayAfter);
        assertTrue(newDelay == delayAfter);
    }

    function test_UpgradeSecurityCouncil() public {
        vm.startPrank(owner);
        address securityCouncilBefore = governance.securityCouncil();
        address newSecurityCouncil = address(bytes20(Utils.randomBytes32("newSecurityCouncil")));
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(governance),
            0,
            abi.encodeCall(IGovernance.updateSecurityCouncil, (newSecurityCouncil))
        );

        governance.scheduleTransparent(op, 0);

        // Check event
        vm.expectEmit(false, false, false, true);
        emit ChangeSecurityCouncil(securityCouncilBefore, newSecurityCouncil);
        governance.execute(op);
        address securityCouncilAfter = governance.securityCouncil();
        assertTrue(securityCouncilBefore != securityCouncilAfter);
        assertTrue(newSecurityCouncil == securityCouncilAfter);
    }
}
