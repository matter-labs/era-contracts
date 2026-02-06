// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {FeeParamsChangeTooFrequent, FeeParamsChangeTooLarge, InvalidPubdataPricingMode, PriorityTxPubdataExceedsMaxPubDataPerBatch, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {FeeParamsWereNotChangedCorrectly} from "../../../../../../../L1TestsErrors.sol";

contract ChangeFeeParamsTest is AdminTest {
    event NewFeeParams(FeeParams oldFeeParams, FeeParams newFeeParams);

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
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 110_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 250_000_000
        });

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));

        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_revertWhen_newMaxPubdataPerBatchIsLessThanMaxPubdataPerTransaction() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        uint32 priorityTxMaxPubdata = 88_000;
        uint32 maxPubdataPerBatch = priorityTxMaxPubdata - 1;
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: maxPubdataPerBatch,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: priorityTxMaxPubdata,
            minimalL2GasPrice: 250_000_000
        });

        vm.expectRevert(PriorityTxPubdataExceedsMaxPubDataPerBatch.selector);

        vm.startPrank(chainTypeManager);
        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_revertWhen_changePubdataPricingMode() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Validium,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 110_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 250_000_000
        });

        vm.expectRevert(InvalidPubdataPricingMode.selector);

        vm.startPrank(chainTypeManager);
        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_revertWhen_PriorityTxPubdataExceedsMaxPubDataPerBatch(
        uint32 maxPubdataPerBatch,
        uint32 priorityTxMaxPubdata
    ) public {
        vm.assume(maxPubdataPerBatch < priorityTxMaxPubdata);

        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: maxPubdataPerBatch,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: priorityTxMaxPubdata,
            minimalL2GasPrice: 250_000_000
        });

        vm.expectRevert(PriorityTxPubdataExceedsMaxPubDataPerBatch.selector);

        vm.startPrank(chainTypeManager);
        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_successfulChange() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        FeeParams memory oldFeeParams = utilsFacet.util_getFeeParams();
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_200_000,
            maxPubdataPerBatch: 120_000,
            maxL2GasPerBatch: 90_000_000,
            priorityTxMaxPubdata: 100_000,
            minimalL2GasPrice: 300_000_000
        });

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewFeeParams(oldFeeParams, newFeeParams);

        vm.startPrank(chainTypeManager);
        adminFacet.changeFeeParams(newFeeParams);

        bytes32 newFeeParamsHash = keccak256(abi.encode(newFeeParams));
        bytes32 currentFeeParamsHash = keccak256(abi.encode(utilsFacet.util_getFeeParams()));
        if (currentFeeParamsHash != newFeeParamsHash) {
            revert FeeParamsWereNotChangedCorrectly();
        }
    }

    function test_revertWhen_changeFeeParamsTooFrequent() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 110_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 260_000_000
        });

        uint256 nowTimestamp = block.timestamp;
        vm.startPrank(chainTypeManager);
        adminFacet.changeFeeParams(newFeeParams);

        vm.expectRevert(abi.encodeWithSelector(FeeParamsChangeTooFrequent.selector, nowTimestamp + 1 days));
        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_revertWhen_changeFeeParamsPriceIncreaseTooLarge() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 110_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 1_000_000_000
        });

        vm.startPrank(chainTypeManager);
        vm.expectPartialRevert(FeeParamsChangeTooLarge.selector);
        adminFacet.changeFeeParams(newFeeParams);
    }
}
