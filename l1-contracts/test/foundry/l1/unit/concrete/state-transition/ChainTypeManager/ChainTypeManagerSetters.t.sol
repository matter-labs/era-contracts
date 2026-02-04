// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ZeroAddress, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract ChainTypeManagerSetters is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    // setPriorityTxMaxGasLimit
    function test_SuccessfulSetPriorityTxMaxGasLimit() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        uint256 newMaxGasLimit = 1000;

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor); // In the ChainTypeManagerTest contract, governor is set as the owner of chainContractAddress
        chainContractAddress.setPriorityTxMaxGasLimit(chainId, newMaxGasLimit);

        uint256 maxGasLimit = gettersFacet.getPriorityTxMaxGasLimit();

        assertEq(maxGasLimit, newMaxGasLimit);
    }

    // setTokenMultiplier
    function test_SuccessfulSetTokenMultiplier() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        uint128 newNominator = 1;
        uint128 newDenominator = 1000;

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setTokenMultiplier(chainId, newNominator, newDenominator);

        uint128 nominator = gettersFacet.baseTokenGasPriceMultiplierNominator();
        uint128 denominator = gettersFacet.baseTokenGasPriceMultiplierDenominator();

        assertEq(newNominator, nominator);
        assertEq(newDenominator, denominator);
    }

    // changeFeeParams
    function test_SuccessfulChangeFeeParams() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1000000,
            maxPubdataPerBatch: 120000,
            maxL2GasPerBatch: 80000000,
            priorityTxMaxPubdata: 99000,
            minimalL2GasPrice: 250000000
        });

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
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
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        GettersFacet gettersFacet = GettersFacet(chainAddress);
        address new_validator = makeAddr("new_validator");

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setValidator(chainId, new_validator, true);

        bool isActive = gettersFacet.isValidator(new_validator);
        assertTrue(isActive);
    }

    // setPorterAvailability
    function test_SuccessfulSetPorterAvailability() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setPorterAvailability(chainId, true);

        bool isAvailable = utilsFacet.util_getZkPorterAvailability();
        assertTrue(isAvailable);
    }

    // setProtocolVersionVerifier - happy path by owner
    function test_SuccessfulSetProtocolVersionVerifierByOwner() public {
        uint256 protocolVersionToSet = 100;
        address newVerifier = makeAddr("newVerifier");

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit IChainTypeManager.NewProtocolVersionVerifier(protocolVersionToSet, newVerifier);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, newVerifier);

        address storedVerifier = chainContractAddress.protocolVersionVerifier(protocolVersionToSet);
        assertEq(storedVerifier, newVerifier);
    }

    // setProtocolVersionVerifier - happy path by admin
    function test_SuccessfulSetProtocolVersionVerifierByAdmin() public {
        uint256 protocolVersionToSet = 200;
        address newVerifier = makeAddr("newVerifier");
        address ctmAdmin = makeAddr("ctmAdmin");

        vm.prank(governor);
        chainContractAddress.setPendingAdmin(ctmAdmin);

        vm.prank(ctmAdmin);
        chainContractAddress.acceptAdmin();

        vm.prank(ctmAdmin);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, newVerifier);

        address storedVerifier = chainContractAddress.protocolVersionVerifier(protocolVersionToSet);
        assertEq(storedVerifier, newVerifier);
    }

    // setProtocolVersionVerifier - unhappy path (zero address)
    function test_RevertWhen_SetProtocolVersionVerifierWithZeroAddress() public {
        uint256 protocolVersionToSet = 100;

        vm.prank(governor);
        vm.expectRevert(ZeroAddress.selector);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, address(0));
    }

    // setProtocolVersionVerifier - unhappy path (unauthorized)
    function test_RevertWhen_SetProtocolVersionVerifierUnauthorized() public {
        uint256 protocolVersionToSet = 100;
        address newVerifier = makeAddr("newVerifier");
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomUser));
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, newVerifier);
    }

    // setProtocolVersionVerifier - can overwrite existing verifier
    function test_CanOverwriteExistingProtocolVersionVerifier() public {
        uint256 protocolVersionToSet = 400;
        address firstVerifier = makeAddr("firstVerifier");
        address secondVerifier = makeAddr("secondVerifier");

        vm.startPrank(governor);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, firstVerifier);
        assertEq(chainContractAddress.protocolVersionVerifier(protocolVersionToSet), firstVerifier);

        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, secondVerifier);
        assertEq(chainContractAddress.protocolVersionVerifier(protocolVersionToSet), secondVerifier);
        vm.stopPrank();
    }
}
