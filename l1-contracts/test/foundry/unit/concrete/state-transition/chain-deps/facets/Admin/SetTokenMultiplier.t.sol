// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, DenominatorIsZero} from "contracts/common/L1ContractErrors.sol";

contract SetTokenMultiplierTest is AdminTest {
    event NewBaseTokenMultiplier(
        uint128 _oldNominator,
        uint128 _oldDenominator,
        uint128 _nominator,
        uint128 _denominator
    );

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        uint128 nominator = 1;
        uint128 denominator = 100;

        vm.startPrank(nonStateTransitionManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonStateTransitionManager));

        adminFacet.setTokenMultiplier(nominator, denominator);
    }

    function test_revertWhen_denominatorIsZero() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        uint128 nominator = 1;
        uint128 denominator = 0;

        vm.startPrank(stateTransitionManager);
        vm.expectRevert(DenominatorIsZero.selector);

        adminFacet.setTokenMultiplier(nominator, denominator);
    }

    function test_successfulSet(uint128 nominator, uint128 denominator) public {
        vm.assume(denominator != 0);

        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();
        uint128 oldNominator = utilsFacet.util_getBaseTokenGasPriceMultiplierNominator();
        uint128 oldDenominator = utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator();

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, nominator, denominator);

        vm.startPrank(stateTransitionManager);
        adminFacet.setTokenMultiplier(nominator, denominator);

        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), nominator);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator(), denominator);
    }
}
