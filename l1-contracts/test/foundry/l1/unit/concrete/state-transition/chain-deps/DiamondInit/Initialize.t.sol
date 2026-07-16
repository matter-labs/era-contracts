// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DiamondInitTest} from "./_DiamondInit_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {ICTMRelease} from "contracts/upgrades/registry/ICTMRelease.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {EmptyAssetId, EmptyBytes32, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract InitializeTest is DiamondInitTest {
    /// @dev Builds the standard genesis cut. Kept separate from the deploy so revert tests can
    ///      place `vm.expectRevert` directly before the proxy creation.
    function _buildCut(uint256 _chainId, address _admin) internal returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: facetCuts,
                initAddress: address(new DiamondInit(false)),
                initCalldata: abi.encodeCall(DiamondInit.initialize, (_chainId, _admin))
            });
    }

    /// @dev Deploys the diamond pranked as the fake CTM — DiamondInit treats the proxy deployer
    ///      (msg.sender) as the CTM.
    function _deployDiamondAsCtm(Diamond.DiamondCutData memory _cut) internal returns (address) {
        vm.prank(Utils.TEST_CHAIN_TYPE_MANAGER);
        return address(new DiamondProxy(block.chainid, _cut));
    }

    function test_revertWhen_verifierIsZeroAddress() public {
        // Mock CTM to return zero address for verifier
        vm.mockCall(
            Utils.TEST_CHAIN_TYPE_MANAGER,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, uint256(0)),
            abi.encode(address(0))
        );

        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN);

        vm.expectRevert(ZeroAddress.selector);

        _deployDiamondAsCtm(cut);
    }

    function test_revertWhen_governorIsZeroAddress() public {
        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, address(0));
        vm.expectRevert(ZeroAddress.selector);
        _deployDiamondAsCtm(cut);
    }

    function test_revertWhen_validatorTimelockIsZeroAddress() public {
        vm.mockCall(
            Utils.TEST_CHAIN_TYPE_MANAGER,
            abi.encodeWithSelector(IChainTypeManager.validatorTimelockPostV29.selector),
            abi.encode(address(0))
        );

        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN);

        vm.expectRevert(ZeroAddress.selector);

        _deployDiamondAsCtm(cut);
    }

    function test_revertWhen_bridgehubAddressIsZero() public {
        vm.mockCall(
            Utils.TEST_CHAIN_TYPE_MANAGER,
            abi.encodeWithSelector(IChainTypeManager.BRIDGE_HUB.selector),
            abi.encode(address(0))
        );
        // The zero bridgehub is also where the asset id would be read from; mock it non-zero so
        // the test pins the bridgehub check specifically.
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(Utils.TEST_BASE_TOKEN_ASSET_ID)
        );

        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN);

        vm.expectRevert(ZeroAddress.selector);

        _deployDiamondAsCtm(cut);
    }

    function test_revertWhen_baseTokenAssetIdIsZero() public {
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(bytes32(0))
        );

        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN);

        vm.expectRevert(EmptyAssetId.selector);

        _deployDiamondAsCtm(cut);
    }

    function test_valuesCorrectWhenSuccessfulInit() public {
        // Mock CTM to return testnetVerifier for this protocol version
        vm.mockCall(
            Utils.TEST_CHAIN_TYPE_MANAGER,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, uint256(0)),
            abi.encode(testnetVerifier)
        );

        UtilsFacet utilsFacet = UtilsFacet(_deployDiamondAsCtm(_buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN)));

        assertEq(utilsFacet.util_getChainId(), Utils.TEST_CHAIN_ID);
        assertEq(utilsFacet.util_getBridgehub(), address(dummyBridgehub));
        assertEq(utilsFacet.util_getChainTypeManager(), Utils.TEST_CHAIN_TYPE_MANAGER);
        assertEq(utilsFacet.util_getBaseTokenAssetId(), Utils.TEST_BASE_TOKEN_ASSET_ID);
        assertEq(utilsFacet.util_getProtocolVersion(), 0);

        // Verifier is now fetched from CTM
        assertEq(address(utilsFacet.util_getVerifier()), testnetVerifier);
        assertEq(utilsFacet.util_getAdmin(), Utils.TEST_CHAIN_ADMIN);
        assertEq(utilsFacet.util_getValidator(Utils.TEST_VALIDATOR_TIMELOCK), true);

        assertEq(utilsFacet.util_getStoredBatchHashes(0), bytes32(0));
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
            Utils.TEST_CHAIN_TYPE_MANAGER,
            abi.encodeWithSelector(IChainTypeManager.currentRelease.selector),
            abi.encode(address(0))
        );

        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN);

        vm.expectRevert(ZeroAddress.selector);

        _deployDiamondAsCtm(cut);
    }

    /// @notice On Era (non-ZKsync-OS) chains the registry must pin non-zero base system contract
    ///         hashes.
    function test_revertWhen_registryReturnsZeroBootloaderHash() public {
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.baseSystemContractHashes.selector),
            abi.encode(bytes32(0), Utils.TEST_BASE_SYSTEM_CONTRACT_HASH, Utils.TEST_BASE_SYSTEM_CONTRACT_HASH)
        );

        Diamond.DiamondCutData memory cut = _buildCut(Utils.TEST_CHAIN_ID, Utils.TEST_CHAIN_ADMIN);

        vm.expectRevert(EmptyBytes32.selector);

        _deployDiamondAsCtm(cut);
    }
}
