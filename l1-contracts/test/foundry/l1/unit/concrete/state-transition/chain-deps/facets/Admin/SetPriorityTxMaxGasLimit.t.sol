// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
import {TooMuchGas, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract SetPriorityTxMaxGasLimitTest is AdminTest {
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");
        uint256 newPriorityTxMaxGasLimit = 100;

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);
    }

    function test_revertWhen_newPriorityTxMaxGasLimitExceedsProtocolCeiling() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint256 newPriorityTxMaxGasLimit = PRIORITY_TX_MAX_GAS_LIMIT + 1;
        uint256 oldPriorityTxMaxGasLimit = utilsFacet.util_getPriorityTxMaxGasLimit();

        vm.startPrank(chainTypeManager);
        vm.expectRevert(TooMuchGas.selector);
        adminFacet.setPriorityTxMaxGasLimit(newPriorityTxMaxGasLimit);

        assertEq(utilsFacet.util_getPriorityTxMaxGasLimit(), oldPriorityTxMaxGasLimit);
    }

    function test_successfulSetAtProtocolCeiling() public {
        _assertSuccessfulSet(PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_successfulSetToZero() public {
        _assertSuccessfulSet(0);
    }

    function testFuzz_successfulSet(uint256 _newPriorityTxMaxGasLimit) public {
        _assertSuccessfulSet(bound(_newPriorityTxMaxGasLimit, 0, PRIORITY_TX_MAX_GAS_LIMIT));
    }

    function _assertSuccessfulSet(uint256 _newPriorityTxMaxGasLimit) internal {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint256 oldPriorityTxMaxGasLimit = utilsFacet.util_getPriorityTxMaxGasLimit();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);

        vm.startPrank(chainTypeManager);
        adminFacet.setPriorityTxMaxGasLimit(_newPriorityTxMaxGasLimit);

        assertEq(utilsFacet.util_getPriorityTxMaxGasLimit(), _newPriorityTxMaxGasLimit);
    }
}
