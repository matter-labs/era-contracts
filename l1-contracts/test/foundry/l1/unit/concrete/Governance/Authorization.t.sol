// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GovernanceTest} from "./_Governance_Shared.t.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract Authorization is GovernanceTest {
    function test_RevertWhen_SchedulingByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert("Ownable: caller is not the owner");
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 0);
    }

    function test_RevertWhen_SchedulingBySecurityCouncil() public {
        vm.prank(securityCouncil);
        vm.expectRevert("Ownable: caller is not the owner");
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 0);
    }

    function test_RevertWhen_SchedulingShadowByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert("Ownable: caller is not the owner");
        governance.scheduleShadow(bytes32(0), 0);
    }

    function test_RevertWhen_SchedulingShadowBySecurityCouncil() public {
        vm.prank(securityCouncil);
        vm.expectRevert("Ownable: caller is not the owner");
        governance.scheduleShadow(bytes32(0), 0);
    }

    function test_RevertWhen_ExecutingByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.execute(op);
    }

    function test_RevertWhen_ExecutingInstantByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.executeInstant(op);
    }

    function test_RevertWhen_ExecutingInstantByOwner() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.executeInstant(op);
    }

    function test_RevertWhen_CancelByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert("Ownable: caller is not the owner");
        governance.cancel(bytes32(0));
    }

    function test_RevertWhen_UpdateDelayByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        governance.updateDelay(0);
    }

    function test_RevertWhen_UpdateDelayByOwner() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        governance.updateDelay(0);
    }

    function test_RevertWhen_UpdateDelayBySecurityCouncil() public {
        vm.prank(securityCouncil);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, securityCouncil));
        governance.updateDelay(0);
    }

    function test_RevertWhen_UpdateSecurityCouncilByUnauthorisedAddress() public {
        vm.prank(randomSigner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        governance.updateSecurityCouncil(address(0));
    }

    function test_RevertWhen_UpdateSecurityCouncilByOwner() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        governance.updateSecurityCouncil(address(0));
    }

    function test_RevertWhen_UpdateSecurityCouncilBySecurityCouncil() public {
        vm.prank(securityCouncil);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, securityCouncil));
        governance.updateSecurityCouncil(address(0));
    }
}
