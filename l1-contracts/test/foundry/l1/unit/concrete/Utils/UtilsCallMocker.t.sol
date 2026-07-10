// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGenesisFacetRegistry} from "contracts/upgrades/registry/IGenesisFacetRegistry.sol";
import {CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_ASSET_TRACKER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

// solhint-enable max-line-length

contract UtilsCallMockerTest is Test {
    address private constant DEFAULT_CHAIN_TYPE_MANAGER = address(0x1234567890876543567890);
    uint256 private constant DEFAULT_PROTOCOL_VERSION = 0;

    // Original function for backward compatibility - uses hardcoded chainTypeManager from makeInitializeData
    function mockDiamondInitInteropCenterCallsWithAddress(
        address bridgehub,
        address assetRouter,
        bytes32 baseTokenAssetId
    ) public {
        // Default chainTypeManager address from Utils.makeInitializeData
        address defaultChainTypeManager = address(0x1234567890876543567890);
        mockDiamondInitInteropCenterCallsWithAddress(bridgehub, assetRouter, baseTokenAssetId, defaultChainTypeManager);
    }

    // Overloaded version that accepts chainTypeManager address
    function mockDiamondInitInteropCenterCallsWithAddress(
        address bridgehub,
        address assetRouter,
        bytes32 baseTokenAssetId,
        address chainTypeManager
    ) public {
        // Default permissionless validator address
        mockDiamondInitInteropCenterCallsWithAddress(
            bridgehub,
            assetRouter,
            baseTokenAssetId,
            chainTypeManager,
            makeAddr("permissionlessValidator")
        );
    }

    // Overloaded version that accepts chainTypeManager and permissionlessValidator addresses
    function mockDiamondInitInteropCenterCallsWithAddress(
        address bridgehub,
        address assetRouter,
        bytes32 baseTokenAssetId,
        address chainTypeManager,
        address permissionlessValidator
    ) public {
        address assetTracker = makeAddr("assetTracker");
        address nativeTokenVault = makeAddr("nativeTokenVault");
        if (assetRouter == address(0)) {
            assetRouter = makeAddr("assetRouter");
        } else if (assetRouter == L2_ASSET_ROUTER_ADDR) {
            nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
            assetTracker = L2_ASSET_TRACKER_ADDR;
        }

        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(assetRouter));
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(nativeTokenVault)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(IL1NativeTokenVault.l1AssetTracker.selector),
            abi.encode(assetTracker)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, baseTokenAssetId),
            abi.encode(block.chainid)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, baseTokenAssetId),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        // Mock PERMISSIONLESS_VALIDATOR on the chainTypeManager
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.PERMISSIONLESS_VALIDATOR.selector),
            abi.encode(permissionlessValidator)
        );
        mockGenesisRegistry(chainTypeManager);
    }

    /// @notice Mocks the CTM's genesis registry pointer and the registry itself for DiamondInit.
    function mockGenesisRegistry(address chainTypeManager) public {
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.genesisRegistry.selector),
            abi.encode(Utils.TEST_GENESIS_REGISTRY)
        );
        mockGenesisRegistryContract();
    }

    /// @notice Mocks the genesis registry at `Utils.TEST_GENESIS_REGISTRY` for DiamondInit.
    /// @dev The registry is mocked rather than deployed on purpose: these fixtures isolate the
    ///      diamond from the CTM (which is itself mocked or initialized at protocol version 0,
    ///      which a real `GenesisRegistry` cannot pin) and install their facets via the cut's
    ///      own `facetCuts`, often with hand-picked selector subsets. The mocked registry
    ///      therefore pins NO facets (empty list, so DiamondInit installs nothing further) and
    ///      only serves the base system contract hashes DiamondInit reads at genesis.
    function mockGenesisRegistryContract() public {
        address genesisRegistry = Utils.TEST_GENESIS_REGISTRY;
        // Selector-only matches: the fixtures use several protocol versions, and the registry
        // answers all of them identically.
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(IGenesisFacetRegistry.newProtocolVersion.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(IGenesisFacetRegistry.facetList.selector),
            abi.encode(new CTMContract[](0))
        );
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(IGenesisFacetRegistry.baseSystemContractHashes.selector),
            abi.encode(
                Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                Utils.TEST_BASE_SYSTEM_CONTRACT_HASH
            )
        );
    }

    /// @notice Mocks the CTM's protocolVersionVerifier call for DiamondInit
    /// @dev The chainTypeManager address (0x1234567890876543567890) and protocolVersion (0)
    ///      match the values used in Utils.makeInitializeData()
    function mockChainTypeManagerVerifier(address verifier) public {
        vm.mockCall(
            DEFAULT_CHAIN_TYPE_MANAGER,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, DEFAULT_PROTOCOL_VERSION),
            abi.encode(verifier)
        );
        mockGenesisRegistry(DEFAULT_CHAIN_TYPE_MANAGER);
    }

    function test() internal virtual {}
}
