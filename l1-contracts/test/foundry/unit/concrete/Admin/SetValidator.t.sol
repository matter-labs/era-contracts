// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_ADMIN_OR_GOVERNOR} from "./_Admin_Shared.t.sol";

contract SetValidatorTest is AdminTest {
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    function test_revertWhen_calledByNonAdminOrGovernor() public {
        address nonAdminOrGovernor = makeAddr("nonAdminOrGovernor");
        address validator = makeAddr("validator");
        bool isActive = true;

        vm.expectRevert(ERROR_ONLY_ADMIN_OR_GOVERNOR);

        vm.startPrank(nonAdminOrGovernor);
        adminFacet.setValidator(validator, isActive);
    }

    function test_calledByGovernor() public {
        address governor = adminFacetWrapper.util_getGovernor();
        address validator = makeAddr("validator");
        bool isActive = true;

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(governor);
        adminFacet.setValidator(validator, isActive);

        assertEq(adminFacetWrapper.util_getValidator(validator), isActive);
    }

    function test_calledByAdmin() public {
        address admin = adminFacetWrapper.util_getAdmin();
        address validator = makeAddr("validator");
        bool isActive = true;

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(admin);
        adminFacet.setValidator(validator, isActive);

        assertEq(adminFacetWrapper.util_getValidator(validator), isActive);
    }

    function test_deactivateValidator() public {
        address admin = adminFacetWrapper.util_getAdmin();
        address validator = makeAddr("validator");
        bool isActive = false;

        adminFacetWrapper.util_setValidator(validator, true);

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(admin);
        adminFacet.setValidator(validator, isActive);

        assertEq(adminFacetWrapper.util_getValidator(validator), isActive);
    }

    function test_reactivateValidator() public {
        address admin = adminFacetWrapper.util_getAdmin();
        address validator = makeAddr("validator");
        bool isActive = true;

        adminFacetWrapper.util_setValidator(validator, false);

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(admin);
        adminFacet.setValidator(validator, isActive);

        assertEq(adminFacetWrapper.util_getValidator(validator), isActive);
    }
}
