// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GovernanceTest} from "./_Governance_Shared.t.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract ConstructorTest is GovernanceTest {
    function test_RevertWhen_AdminAddressIsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        new Governance(address(0), securityCouncil, 0);
    }

    function test_SuccessfulConstruction() public {
        Governance governance = new Governance(owner, securityCouncil, 0);

        assertEq(governance.securityCouncil(), securityCouncil);
        assertEq(governance.minDelay(), 0);
        assertEq(governance.owner(), owner);
    }
}
