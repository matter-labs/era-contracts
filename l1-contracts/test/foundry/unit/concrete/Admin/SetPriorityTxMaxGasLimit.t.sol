// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_GOVERNOR} from "./_Admin_Shared.t.sol";

import {MAX_GAS_PER_TRANSACTION} from "solpp/common/Config.sol";

contract SetPriorityTxMaxGasLimitTest is AdminTest {
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    function test_revertWhen_calledByNonGovernor() public {
        address nonGovernor = makeAddr("nonGovernor");
        uint256 newPriorityTxMaxGasLimit = 100;

        vm.startPrank(nonGovernor);
        vm.expectRevert(ERROR_ONLY_GOVERNOR);

        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);
    }

    function test_revertWhen_newPriorityTxMaxGasLimitIsGreaterThanMaxGasPerTransaction() public {
        address governor = adminFacetWrapper.util_getGovernor();
        uint256 newPriorityTxMaxGasLimit = MAX_GAS_PER_TRANSACTION + 1;

        vm.expectRevert(bytes.concat("n5"));

        vm.startPrank(governor);
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);
    }

    function test_successfulSet() public {
        address governor = adminFacetWrapper.util_getGovernor();
        uint256 oldPriorityTxMaxGasLimit = adminFacetWrapper.util_getPriorityTxMaxGasLimit();
        uint256 newPriorityTxMaxGasLimit = 100;

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, newPriorityTxMaxGasLimit);

        vm.startPrank(governor);
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);

        assertEq(adminFacetWrapper.util_getPriorityTxMaxGasLimit(), newPriorityTxMaxGasLimit);
    }
}
