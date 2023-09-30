// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {GovernanceTest} from "./_Governance_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IGovernance} from "../../../../../cache/solpp-generated-contracts/governance/IGovernance.sol";

contract SeflUpgradesTest is GovernanceTest {
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
        require(delayBefore != delayAfter, "Delays are the same");
        require(newDelay == delayAfter, "Delay should have been changed");
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
        require(securityCouncilBefore != securityCouncilAfter, "Security councils are the same");
        require(newSecurityCouncil == securityCouncilAfter, "SC should have been changed");
    }
}
