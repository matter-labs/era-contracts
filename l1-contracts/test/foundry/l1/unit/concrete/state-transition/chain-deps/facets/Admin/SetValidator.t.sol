// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract SetValidatorTest is AdminTest {
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");
        address validator = makeAddr("validator");
        bool isActive = true;

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        adminFacet.setValidator(validator, isActive);
    }

    function test_deactivateValidator() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        address validator = makeAddr("validator");
        bool isActive = false;

        utilsFacet.util_setValidator(validator, true);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(chainTypeManager);
        adminFacet.setValidator(validator, isActive);

        assertEq(utilsFacet.util_getValidator(validator), isActive);
    }

    function test_reactivateValidator() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        address validator = makeAddr("validator");
        bool isActive = true;

        utilsFacet.util_setValidator(validator, false);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(chainTypeManager);
        adminFacet.setValidator(validator, isActive);

        assertEq(utilsFacet.util_getValidator(validator), isActive);
    }
}
