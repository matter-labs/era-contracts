// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DiamondInitTest} from "./_DiamondInit_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {IGenesisFacetRegistry} from "contracts/upgrades/registry/IGenesisFacetRegistry.sol";
import {EmptyAssetId, EmptyBytes32, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

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
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_governorIsZeroAddress() public {
        initializeData.admin = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_validatorTimelockIsZeroAddress() public {
        initializeData.validatorTimelock = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_bridgehubAddressIsZero() public {
        initializeData.bridgehub = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_chainTypeManagerAddressIsZero() public {
        initializeData.chainTypeManager = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_baseTokenAssetIdIsZero() public {
        initializeData.baseTokenAssetId = bytes32(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
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
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
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
        // The base system contract hashes are no longer passed in calldata: DiamondInit reads
        // them from the genesis registry the CTM pins (mocked in UtilsCallMocker).
        assertEq(utilsFacet.util_getL2BootloaderBytecodeHash(), Utils.TEST_BASE_SYSTEM_CONTRACT_HASH);
        assertEq(utilsFacet.util_getL2DefaultAccountBytecodeHash(), Utils.TEST_BASE_SYSTEM_CONTRACT_HASH);
        assertEq(utilsFacet.util_getL2EvmEmulatorBytecodeHash(), Utils.TEST_BASE_SYSTEM_CONTRACT_HASH);
    }

    /// @notice The genesis registry is mandatory: a CTM that pins none must make chain creation
    ///         fail loudly.
    function test_revertWhen_genesisRegistryIsZeroAddress() public {
        vm.mockCall(
            initializeData.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.genesisRegistry.selector),
            abi.encode(address(0))
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    /// @notice On Era (non-ZKsync-OS) chains the registry must pin non-zero base system contract
    ///         hashes.
    function test_revertWhen_registryReturnsZeroBootloaderHash() public {
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(IGenesisFacetRegistry.baseSystemContractHashes.selector),
            abi.encode(bytes32(0), Utils.TEST_BASE_SYSTEM_CONTRACT_HASH, Utils.TEST_BASE_SYSTEM_CONTRACT_HASH)
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeCall(DiamondInit.initialize, (initializeData))
        });

        vm.expectRevert(EmptyBytes32.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }
}
