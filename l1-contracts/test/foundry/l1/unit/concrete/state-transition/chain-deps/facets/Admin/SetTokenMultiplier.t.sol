// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {DenominatorIsZero, FeeParamsChangeTooLarge, TokenMultiplierChangeTooFrequent, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

contract SetTokenMultiplierTest is AdminTest {
    event NewBaseTokenMultiplier(
        uint128 _oldNominator,
        uint128 _oldDenominator,
        uint128 _nominator,
        uint128 _denominator
    );

    function setUp() public override {
        super.setUp();

        utilsFacet.util_setBaseTokenGasPriceMultiplierNominator(1);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setFeeParams(
            FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            })
        );
    }

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        uint128 nominator = 1;
        uint128 denominator = 100;

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));

        adminFacet.setTokenMultiplier(nominator, denominator);
    }

    function test_revertWhen_denominatorIsZero() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        uint128 nominator = 1;
        uint128 denominator = 0;

        vm.startPrank(chainTypeManager);

        vm.expectRevert(DenominatorIsZero.selector);
        adminFacet.setTokenMultiplier(nominator, denominator);
    }

    function test_successfulSet() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint128 oldNominator = utilsFacet.util_getBaseTokenGasPriceMultiplierNominator();
        uint128 oldDenominator = utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator();

        uint128 nominator = 11;
        uint128 denominator = 10;

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, nominator, denominator);

        vm.startPrank(chainTypeManager);
        adminFacet.setTokenMultiplier(nominator, denominator);

        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), nominator);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator(), denominator);
    }

    function test_revertWhen_setTokenMultiplierTooFrequent() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint128 nominator = 10;
        uint128 denominator = 9;

        uint256 nowTimestamp = block.timestamp;
        vm.startPrank(chainTypeManager);
        adminFacet.setTokenMultiplier(nominator, denominator);

        vm.expectRevert(abi.encodeWithSelector(TokenMultiplierChangeTooFrequent.selector, nowTimestamp + 1 days));
        adminFacet.setTokenMultiplier(nominator, denominator);
    }

    function test_revertWhen_setTokenMultiplierPriceIncreaseTooLarge() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint128 nominator = 100;
        uint128 denominator = 1;

        vm.startPrank(chainTypeManager);
        vm.expectPartialRevert(FeeParamsChangeTooLarge.selector);
        adminFacet.setTokenMultiplier(nominator, denominator);
    }
}
