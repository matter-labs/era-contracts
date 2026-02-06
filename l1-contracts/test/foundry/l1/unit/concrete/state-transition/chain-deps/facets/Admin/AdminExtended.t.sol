// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./_Admin_Shared.t.sol";
import {Unauthorized, DiamondNotFrozen, DenominatorIsZero, TooMuchGas, PriorityTxPubdataExceedsMaxPubDataPerBatch, InvalidPubdataPricingMode, HashMismatch, ProtocolIdMismatch, InvalidL2DACommitmentScheme} from "contracts/common/L1ContractErrors.sol";
import {L1DAValidatorAddressIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {FeeParams, PubdataPricingMode, L2DACommitmentScheme} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {MAX_GAS_PER_TRANSACTION} from "contracts/common/Config.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

/// @title Extended tests for AdminFacet to increase coverage
contract AdminExtendedTest is AdminTest {
    function setUp() public override {
        super.setUp();
    }

    function test_SetTokenMultiplier_DenominatorIsZero() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        vm.prank(address(this));
        vm.expectRevert(DenominatorIsZero.selector);
        adminFacet.setTokenMultiplier(1, 0);
    }

    function test_SetPriorityTxMaxGasLimit_TooMuchGas() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        vm.prank(address(this));
        vm.expectRevert(TooMuchGas.selector);
        adminFacet.setPriorityTxMaxGasLimit(MAX_GAS_PER_TRANSACTION + 1);
    }

    function test_ChangeFeeParams_PubdataExceedsMax() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        FeeParams memory currentFeeParams = utilsFacet.util_getFeeParams();
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: currentFeeParams.pubdataPricingMode,
            batchOverheadL1Gas: 100,
            maxPubdataPerBatch: 100, // Less than priorityTxMaxPubdata
            maxL2GasPerBatch: 1000,
            priorityTxMaxPubdata: 200, // More than maxPubdataPerBatch
            minimalL2GasPrice: 100
        });

        vm.prank(address(this));
        vm.expectRevert(PriorityTxPubdataExceedsMaxPubDataPerBatch.selector);
        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_ChangeFeeParams_InvalidPubdataPricingMode() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        // Set initial fee params with Rollup mode
        FeeParams memory currentFeeParams = utilsFacet.util_getFeeParams();

        // Try to change to Validium mode
        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: currentFeeParams.pubdataPricingMode == PubdataPricingMode.Rollup
                ? PubdataPricingMode.Validium
                : PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 100,
            maxPubdataPerBatch: 1000,
            maxL2GasPerBatch: 1000,
            priorityTxMaxPubdata: 100,
            minimalL2GasPrice: 100
        });

        vm.prank(address(this));
        vm.expectRevert(InvalidPubdataPricingMode.selector);
        adminFacet.changeFeeParams(newFeeParams);
    }

    function test_SetDAValidatorPair_L1DAValidatorAddressIsZero() public {
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        vm.expectRevert(L1DAValidatorAddressIsZero.selector);
        adminFacet.setDAValidatorPair(address(0), L2DACommitmentScheme.PUBDATA_KECCAK256);
    }

    function test_SetDAValidatorPair_InvalidL2DACommitmentScheme() public {
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidL2DACommitmentScheme.selector, 0));
        adminFacet.setDAValidatorPair(makeAddr("validator"), L2DACommitmentScheme.NONE);
    }

    function test_UnfreezeDiamond_NotFrozen() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        // Try to unfreeze when not frozen
        vm.prank(address(this));
        vm.expectRevert(DiamondNotFrozen.selector);
        adminFacet.unfreezeDiamond();
    }

    function test_SetTokenMultiplier_Success() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        vm.prank(address(this));
        adminFacet.setTokenMultiplier(5, 3);

        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), 5);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator(), 3);
    }

    function test_AcceptAdmin_Unauthorized() public {
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomUser));
        adminFacet.acceptAdmin();
    }

    function test_SetPendingAdmin_AndAccept() public {
        address admin = utilsFacet.util_getAdmin();
        address newPendingAdmin = makeAddr("newPendingAdmin");

        vm.prank(admin);
        adminFacet.setPendingAdmin(newPendingAdmin);

        assertEq(utilsFacet.util_getPendingAdmin(), newPendingAdmin);

        vm.prank(newPendingAdmin);
        adminFacet.acceptAdmin();

        assertEq(utilsFacet.util_getAdmin(), newPendingAdmin);
        assertEq(utilsFacet.util_getPendingAdmin(), address(0));
    }

    function test_SetValidator() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        address validator = makeAddr("validator");

        vm.prank(address(this));
        adminFacet.setValidator(validator, true);

        assertTrue(utilsFacet.util_getValidator(validator));

        vm.prank(address(this));
        adminFacet.setValidator(validator, false);

        assertFalse(utilsFacet.util_getValidator(validator));
    }

    function test_SetPorterAvailability() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        vm.prank(address(this));
        adminFacet.setPorterAvailability(true);

        assertTrue(utilsFacet.util_getZkPorterAvailability());

        vm.prank(address(this));
        adminFacet.setPorterAvailability(false);

        assertFalse(utilsFacet.util_getZkPorterAvailability());
    }

    function test_SetPubdataPricingMode() public {
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);

        FeeParams memory feeParams = utilsFacet.util_getFeeParams();
        assertEq(uint8(feeParams.pubdataPricingMode), uint8(PubdataPricingMode.Validium));
    }

    function test_SetTransactionFilterer() public {
        address admin = utilsFacet.util_getAdmin();
        address filterer = makeAddr("filterer");

        vm.prank(admin);
        adminFacet.setTransactionFilterer(filterer);
    }

    function test_UpgradeChainFromVersion_HashMismatch() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        uint256 oldProtocolVersion = 0;
        utilsFacet.util_setProtocolVersion(oldProtocolVersion);

        // Create a diamond cut with wrong hash
        Diamond.FacetCut[] memory emptyFacets = new Diamond.FacetCut[](0);
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: emptyFacets,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        // Mock the upgradeCutHash to return a different hash
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector, oldProtocolVersion),
            abi.encode(bytes32(uint256(123)))
        );

        bytes32 inputHash = keccak256(abi.encode(diamondCut));
        bytes32 expectedHash = bytes32(uint256(123));

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(HashMismatch.selector, expectedHash, inputHash));
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCut);
    }

    function test_UpgradeChainFromVersion_ProtocolIdMismatch() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        uint256 currentVersion = 5;
        uint256 wrongOldVersion = 3;
        utilsFacet.util_setProtocolVersion(currentVersion);

        Diamond.FacetCut[] memory emptyFacets = new Diamond.FacetCut[](0);
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: emptyFacets,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        // Mock the upgradeCutHash to match
        bytes32 cutHash = keccak256(abi.encode(diamondCut));
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector, wrongOldVersion),
            abi.encode(cutHash)
        );

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, currentVersion, wrongOldVersion));
        adminFacet.upgradeChainFromVersion(address(adminFacet), wrongOldVersion, diamondCut);
    }

    function testFuzz_SetTokenMultiplier(uint128 nominator, uint128 denominator) public {
        vm.assume(denominator != 0);

        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        vm.prank(address(this));
        adminFacet.setTokenMultiplier(nominator, denominator);

        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierNominator(), nominator);
        assertEq(utilsFacet.util_getBaseTokenGasPriceMultiplierDenominator(), denominator);
    }

    function test_ExecuteUpgrade_OnlyChainTypeManager() public {
        vm.prank(address(dummyBridgehub));
        utilsFacet.util_setChainTypeManager(address(this));

        Diamond.FacetCut[] memory emptyFacets = new Diamond.FacetCut[](0);
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: emptyFacets,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.prank(address(this));
        adminFacet.executeUpgrade(diamondCut);
    }
}
