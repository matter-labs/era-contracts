// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {MAX_GAS_PER_TRANSACTION} from "contracts/common/Config.sol";
import {Unauthorized, TooMuchGas} from "contracts/common/L1ContractErrors.sol";

contract SetPriorityTxMaxGasLimitTest is AdminTest {
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");
        uint256 newPriorityTxMaxGasLimit = 100;

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);
    }

    function test_revertWhen_newPriorityTxMaxGasLimitIsGreaterThanMaxGasPerTransaction() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint256 newPriorityTxMaxGasLimit = MAX_GAS_PER_TRANSACTION + 1;

        vm.startPrank(chainTypeManager);
        vm.expectRevert(TooMuchGas.selector);
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);
    }

    function test_successfulSet() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint256 oldPriorityTxMaxGasLimit = utilsFacet.util_getPriorityTxMaxGasLimit();
        uint256 newPriorityTxMaxGasLimit = 100;

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, newPriorityTxMaxGasLimit);

        vm.startPrank(chainTypeManager);
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);

        assertEq(utilsFacet.util_getPriorityTxMaxGasLimit(), newPriorityTxMaxGasLimit);
    }
}
