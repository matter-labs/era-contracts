// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract SetPorterAvailabilityTest is AdminTest {
    event IsPorterAvailableStatusUpdate(bool isPorterAvailable);

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");
        bool isPorterAvailable = true;

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        adminFacet.setPorterAvailability(isPorterAvailable);
    }

    function test_setPorterAvailabilityToFalse() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        bool isPorterAvailable = false;

        utilsFacet.util_setZkPorterAvailability(true);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit IsPorterAvailableStatusUpdate(isPorterAvailable);

        vm.startPrank(chainTypeManager);
        adminFacet.setPorterAvailability(isPorterAvailable);

        assertEq(utilsFacet.util_getZkPorterAvailability(), isPorterAvailable);
    }

    function test_setPorterAvailabilityToTrue() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        bool isPorterAvailable = true;

        utilsFacet.util_setZkPorterAvailability(false);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit IsPorterAvailableStatusUpdate(isPorterAvailable);

        vm.startPrank(chainTypeManager);
        adminFacet.setPorterAvailability(isPorterAvailable);

        assertEq(utilsFacet.util_getZkPorterAvailability(), isPorterAvailable);
    }
}
