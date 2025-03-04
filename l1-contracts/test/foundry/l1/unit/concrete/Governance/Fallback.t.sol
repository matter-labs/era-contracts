// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GovernanceTest} from "./_Governance_Shared.t.sol";

contract ExecutingTest is GovernanceTest {
    function test_SendEtherToGovernance() public {
        startHoax(randomSigner);
        payable(address(governance)).transfer(100);
    }

    function test_RevertWhen_CallWithRandomData() public {
        startHoax(randomSigner);
        (bool success, ) = address(governance).call{value: 100}("11223344");
        assertFalse(success);
    }
}
