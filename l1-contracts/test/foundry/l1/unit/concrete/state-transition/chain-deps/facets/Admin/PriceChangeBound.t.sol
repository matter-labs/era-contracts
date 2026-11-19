// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {FeeParamsChangeTooLarge} from "contracts/common/L1ContractErrors.sol";
import {DEFAULT_MAX_L2_GAS_PER_BATCH, PRICE_REFERENCE_L1_GAS} from "contracts/common/Config.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

/// @notice The price-change bound of `setTokenMultiplier` and `changeFeeParams` once Priority Mode can be
/// activated, with the focus on small prices, zero included. See
/// {protocol-docs/system/contracts/chain_management/stage1.md}.
/// @dev The fee params below make the price the bound compares equal to `minimalL2GasPrice + nominator`:
/// the denominator turns the reference L1 gas price into `nominator`, the batch overhead adds exactly that
/// to the L2 gas price, and the pubdata term stays below it.
contract PriceChangeBoundTest is AdminTest {
    uint128 internal constant DENOMINATOR = uint128(PRICE_REFERENCE_L1_GAS);

    address internal chainTypeManager;

    function setUp() public override {
        super.setUp();

        chainTypeManager = utilsFacet.util_getChainTypeManager();
        utilsFacet.util_setPriorityModeCanBeActivated(true);
        // The price starts at zero, and the priority queue of the fresh chain is empty.
        _setPrice({_minimalL2GasPrice: 0, _nominator: 0});
    }

    function _feeParams(uint64 _minimalL2GasPrice) internal pure returns (FeeParams memory) {
        return
            FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: DEFAULT_MAX_L2_GAS_PER_BATCH,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: DEFAULT_MAX_L2_GAS_PER_BATCH,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: _minimalL2GasPrice
            });
    }

    function _setPrice(uint64 _minimalL2GasPrice, uint128 _nominator) internal {
        utilsFacet.util_setFeeParams(_feeParams(_minimalL2GasPrice));
        utilsFacet.util_setBaseTokenGasPriceMultiplierNominator(_nominator);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(DENOMINATOR);
    }

    /// @notice The highest price one update may set, written independently of the contract's formula.
    function _maxAllowedPrice(uint256 _oldPrice) internal pure returns (uint256) {
        return _oldPrice + (_oldPrice * 3) / 10;
    }

    /// @notice Regression test: at a zero price with an empty priority queue the bound used to be skipped,
    /// so one call could set any multiplier.
    function test_revertWhen_priceIsZeroAndTokenMultiplierJumps() public {
        uint256 newPrice = uint256(type(uint128).max) * PRICE_REFERENCE_L1_GAS;

        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, 0, newPrice, 0));
        adminFacet.setTokenMultiplier(type(uint128).max, 1);

        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), 0);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator(), DENOMINATOR);
    }

    /// @notice The same regression through the other setter.
    function test_revertWhen_priceIsZeroAndFeeParamsJump() public {
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, 0, 1 gwei, 0));
        adminFacet.changeFeeParams(_feeParams(1 gwei));

        assertEq(utilsFacet.util_getFeeParams().minimalL2GasPrice, 0);
    }

    /// @notice 13/10 rounds a price below 4 back to itself, so such a price cannot be increased at all.
    function test_revertWhen_priceBelowFourIncreases() public {
        for (uint128 price = 0; price < 4; ++price) {
            _setPrice({_minimalL2GasPrice: 0, _nominator: price});

            vm.prank(chainTypeManager);
            vm.expectRevert(abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, price, price + 1, price));
            adminFacet.setTokenMultiplier(price + 1, DENOMINATOR);
        }

        // From 4 on the ratio leaves room: 4 * 13 / 10 = 5.
        _setPrice({_minimalL2GasPrice: 0, _nominator: 4});
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, 4, 6, 5));
        adminFacet.setTokenMultiplier(6, DENOMINATOR);

        vm.prank(chainTypeManager);
        adminFacet.setTokenMultiplier(5, DENOMINATOR);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), 5);
    }

    /// @notice A price may be lowered to zero, but it cannot be raised again from there.
    function test_revertWhen_priceLoweredToZeroThenRaised() public {
        _setPrice({_minimalL2GasPrice: 0, _nominator: 1});

        vm.prank(chainTypeManager);
        adminFacet.setTokenMultiplier(0, DENOMINATOR);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, 0, 1, 0));
        adminFacet.setTokenMultiplier(1, DENOMINATOR);
    }

    function testFuzz_setTokenMultiplierRespectsBound(uint64 _oldPrice, uint64 _newPrice) public {
        _setPrice({_minimalL2GasPrice: 0, _nominator: _oldPrice});
        bool reverts = _expectRevertIfOutOfBound(_oldPrice, _newPrice);

        vm.prank(chainTypeManager);
        adminFacet.setTokenMultiplier(_newPrice, DENOMINATOR);

        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), reverts ? _oldPrice : _newPrice);
    }

    function testFuzz_changeFeeParamsRespectsBound(uint64 _oldPrice, uint64 _newPrice) public {
        _setPrice({_minimalL2GasPrice: _oldPrice, _nominator: 0});
        bool reverts = _expectRevertIfOutOfBound(_oldPrice, _newPrice);

        vm.prank(chainTypeManager);
        adminFacet.changeFeeParams(_feeParams(_newPrice));

        assertEq(utilsFacet.util_getFeeParams().minimalL2GasPrice, reverts ? _oldPrice : _newPrice);
    }

    function _expectRevertIfOutOfBound(uint256 _oldPrice, uint256 _newPrice) internal returns (bool reverts) {
        uint256 maxAllowedPrice = _maxAllowedPrice(_oldPrice);
        uint256 minAllowedPrice = (_oldPrice * 10) / 13;
        if (_newPrice > maxAllowedPrice) {
            vm.expectRevert(
                abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, _oldPrice, _newPrice, maxAllowedPrice)
            );
            return true;
        }
        if (_newPrice < minAllowedPrice) {
            vm.expectRevert(
                abi.encodeWithSelector(FeeParamsChangeTooLarge.selector, _oldPrice, _newPrice, minAllowedPrice)
            );
            return true;
        }
    }
}
