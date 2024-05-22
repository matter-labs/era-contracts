// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";

contract StateTransitionManagerSetters is StateTransitionManagerTest {
    // setPriorityTxMaxGasLimit
    function test_SuccessfulSetPriorityTxMaxGasLimit() public {
        createNewChain(getDiamondCutData(diamondInit));

        address chainAddress = chainContractAddress.getHyperchain(chainId);
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        vm.stopPrank();
        vm.startPrank(governor);

        uint256 newMaxGasLimit = 1000;
        chainContractAddress.setPriorityTxMaxGasLimit(chainId, newMaxGasLimit);

        uint256 maxGasLimit = gettersFacet.getPriorityTxMaxGasLimit();

        assertEq(maxGasLimit, newMaxGasLimit);
    }

    // setTokenMultiplier
    function test_SuccessfulSetTokenMultiplier() public {
        createNewChain(getDiamondCutData(diamondInit));

        address chainAddress = chainContractAddress.getHyperchain(chainId);
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        vm.stopPrank();
        vm.startPrank(governor);

        uint128 newNominator = 1;
        uint128 newDenominator = 1000;
        chainContractAddress.setTokenMultiplier(chainId, newNominator, newDenominator);

        uint128 nominator = gettersFacet.baseTokenGasPriceMultiplierNominator();
        uint128 denominator = gettersFacet.baseTokenGasPriceMultiplierDenominator();

        assertEq(newNominator, nominator);
        assertEq(newDenominator, denominator);
    }

    // changeFeeParams
    function test_SuccessfulChangeFeeParams() public {
        createNewChain(getDiamondCutData(diamondInit));

        address chainAddress = chainContractAddress.getHyperchain(chainId);
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        vm.stopPrank();
        vm.startPrank(governor);

        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1000000,
            maxPubdataPerBatch: 120000,
            maxL2GasPerBatch: 80000000,
            priorityTxMaxPubdata: 99000,
            minimalL2GasPrice: 250000000
        });

        chainContractAddress.changeFeeParams(chainId, newFeeParams);

        FeeParams memory feeParams = utilsFacet.util_getFeeParams();

        assertEq(feeParams.batchOverheadL1Gas, newFeeParams.batchOverheadL1Gas);
        assertEq(feeParams.maxPubdataPerBatch, newFeeParams.maxPubdataPerBatch);
        assertEq(feeParams.maxL2GasPerBatch, newFeeParams.maxL2GasPerBatch);
        assertEq(feeParams.priorityTxMaxPubdata, newFeeParams.priorityTxMaxPubdata);
        assertEq(feeParams.minimalL2GasPrice, newFeeParams.minimalL2GasPrice);
    }

    // setValidator
    function test_SuccessfulSetValidator() public {
        createNewChain(getDiamondCutData(diamondInit));

        address chainAddress = chainContractAddress.getHyperchain(chainId);
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        vm.stopPrank();
        vm.startPrank(governor);

        address validator = address(0x1);
        chainContractAddress.setValidator(chainId, validator, true);

        bool isActive = gettersFacet.isValidator(validator);
        assertTrue(isActive);
    }

    // setPorterAvailability
    function test_SuccessfulSetPorterAvailability() public {
        createNewChain(getDiamondCutData(diamondInit));

        address chainAddress = chainContractAddress.getHyperchain(chainId);
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        vm.stopPrank();
        vm.startPrank(governor);

        chainContractAddress.setPorterAvailability(chainId, true);

        bool isAvailable = utilsFacet.util_getZkPorterAvailability();
        assertTrue(isAvailable);
    }
}
