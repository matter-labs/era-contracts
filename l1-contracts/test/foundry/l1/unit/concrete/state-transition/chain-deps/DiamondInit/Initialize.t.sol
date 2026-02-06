// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DiamondInitTest} from "./_DiamondInit_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MAX_GAS_PER_TRANSACTION} from "contracts/common/Config.sol";
import {EmptyAssetId, TooMuchGas, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract InitializeTest is DiamondInitTest {
    function test_revertWhen_verifierIsZeroAddress() public {
        // Mock CTM to return zero address for verifier
        vm.mockCall(
            initializeData.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, initializeData.protocolVersion),
            abi.encode(address(0))
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_governorIsZeroAddress() public {
        initializeData.admin = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_validatorTimelockIsZeroAddress() public {
        initializeData.validatorTimelock = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_bridgehubAddressIsZero() public {
        initializeData.bridgehub = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_chainTypeManagerAddressIsZero() public {
        initializeData.chainTypeManager = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_baseTokenAssetIdIsZero() public {
        initializeData.baseTokenAssetId = bytes32(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(EmptyAssetId.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_valuesCorrectWhenSuccessfulInit() public {
        // Mock CTM to return testnetVerifier for this protocol version
        vm.mockCall(
            initializeData.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, initializeData.protocolVersion),
            abi.encode(testnetVerifier)
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        UtilsFacet utilsFacet = UtilsFacet(address(diamondProxy));

        assertEq(utilsFacet.util_getChainId(), initializeData.chainId);
        assertEq(utilsFacet.util_getBridgehub(), initializeData.bridgehub);
        assertEq(utilsFacet.util_getChainTypeManager(), initializeData.chainTypeManager);
        assertEq(utilsFacet.util_getBaseTokenAssetId(), initializeData.baseTokenAssetId);
        assertEq(utilsFacet.util_getProtocolVersion(), initializeData.protocolVersion);

        // Verifier is now fetched from CTM
        assertEq(address(utilsFacet.util_getVerifier()), testnetVerifier);
        assertEq(utilsFacet.util_getAdmin(), initializeData.admin);
        assertEq(utilsFacet.util_getValidator(initializeData.validatorTimelock), true);

        assertEq(utilsFacet.util_getStoredBatchHashes(0), initializeData.storedBatchZero);
        assertEq(utilsFacet.util_getL2BootloaderBytecodeHash(), initializeData.l2BootloaderBytecodeHash);
        assertEq(utilsFacet.util_getL2DefaultAccountBytecodeHash(), initializeData.l2DefaultAccountBytecodeHash);
        assertEq(utilsFacet.util_getL2EvmEmulatorBytecodeHash(), initializeData.l2EvmEmulatorBytecodeHash);
    }
}
