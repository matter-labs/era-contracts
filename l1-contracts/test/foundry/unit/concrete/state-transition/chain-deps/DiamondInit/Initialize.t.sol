// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DiamondInitTest} from "./_DiamondInit_Shared.t.sol";
import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MAX_GAS_PER_TRANSACTION} from "contracts/common/Config.sol";

contract InitializeTest is DiamondInitTest {
    function test_revertWhen_verifierIsZeroAddress() public {
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);
        initializeData.verifier = IVerifier(address(0));

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(bytes.concat("vt"));
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_governorIsZeroAddress() public {
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);
        initializeData.admin = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(bytes.concat("vy"));
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_validatorTimelockIsZeroAddress() public {
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);
        initializeData.validatorTimelock = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(bytes.concat("hc"));
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_priorityTxMaxGasLimitIsGreaterThanMaxGasPerTransaction() public {
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);
        initializeData.priorityTxMaxGasLimit = MAX_GAS_PER_TRANSACTION + 1;

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(bytes.concat("vu"));
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_valuesCorrectWhenSuccessfulInit() public {
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        UtilsFacet utilsFacet = UtilsFacet(address(diamondProxy));

        assertEq(utilsFacet.util_getChainId(), initializeData.chainId);
        assertEq(utilsFacet.util_getBridgehub(), initializeData.bridgehub);
        assertEq(utilsFacet.util_getStateTransitionManager(), initializeData.stateTransitionManager);
        assertEq(utilsFacet.util_getBaseToken(), initializeData.baseToken);
        assertEq(utilsFacet.util_getBaseTokenBridge(), initializeData.baseTokenBridge);
        assertEq(utilsFacet.util_getProtocolVersion(), initializeData.protocolVersion);

        assertEq(address(utilsFacet.util_getVerifier()), address(initializeData.verifier));
        assertEq(utilsFacet.util_getAdmin(), initializeData.admin);
        assertEq(utilsFacet.util_getValidator(initializeData.validatorTimelock), true);

        assertEq(utilsFacet.util_getStoredBatchHashes(0), initializeData.storedBatchZero);
        assertEq(
            keccak256(abi.encode(utilsFacet.util_getVerifierParams())),
            keccak256(abi.encode(initializeData.verifierParams))
        );
        assertEq(utilsFacet.util_getL2BootloaderBytecodeHash(), initializeData.l2BootloaderBytecodeHash);
        assertEq(utilsFacet.util_getL2DefaultAccountBytecodeHash(), initializeData.l2DefaultAccountBytecodeHash);
        assertEq(utilsFacet.util_getPriorityTxMaxGasLimit(), initializeData.priorityTxMaxGasLimit);
        assertEq(
            keccak256(abi.encode(utilsFacet.util_getFeeParams())),
            keccak256(abi.encode(initializeData.feeParams))
        );
    }
}
