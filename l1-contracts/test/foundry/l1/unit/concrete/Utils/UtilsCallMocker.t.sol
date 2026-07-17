// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease, GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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
        // DiamondInit derives everything but (chainId, admin) from the CTM (= the proxy
        // deployer) and the bridgehub; some fixtures pass a zero asset id, which DiamondInit
        // rejects, so substitute the shared test constant.
        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = Utils.TEST_BASE_TOKEN_ASSET_ID;
        }
        mockCtmDerivedInitValues(
            chainTypeManager,
            bridgehub,
            baseTokenAssetId,
            Utils.TEST_VALIDATOR_TIMELOCK,
            bytes32(0)
        );

        address nativeTokenVault = makeAddr("nativeTokenVault");
        if (assetRouter == address(0)) {
            assetRouter = makeAddr("assetRouter");
        } else if (assetRouter == L2_ASSET_ROUTER_ADDR) {
            nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
        }

        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(assetRouter));
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(nativeTokenVault)
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

    /// @notice Mocks the CTM getters DiamondInit derives its initialization values from — the
    ///         CTM is `msg.sender` during the diamond proxy construction, so direct-diamond
    ///         fixtures prank as `chainTypeManager` and mock these on it. Also mocks the
    ///         bridgehub's `baseTokenAssetId` lookup (selector-only: any chain id).
    /// @dev Call again with different values to override (later mocks win).
    function mockCtmDerivedInitValues(
        address chainTypeManager,
        address bridgehub,
        bytes32 baseTokenAssetId,
        address validatorTimelock,
        bytes32 storedBatchZero
    ) public {
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.BRIDGE_HUB.selector),
            abi.encode(bridgehub)
        );
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.validatorTimelockPostV29.selector),
            abi.encode(validatorTimelock)
        );
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.storedBatchZero.selector),
            abi.encode(storedBatchZero)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );
    }

    /// @notice Mocks the CTM's genesis registry pointer and the registry itself for DiamondInit.
    function mockGenesisRegistry(address chainTypeManager) public {
        vm.mockCall(
            chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.currentRelease.selector),
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
        vm.mockCall(genesisRegistry, abi.encodeWithSelector(ICTMRelease.validate.selector), bytes(""));
        vm.mockCall(genesisRegistry, abi.encodeWithSelector(ICTMRelease.verifyAll.selector), abi.encode(true));
        // VM identity is read from the release's DiamondInit immutable; the mocked registry's
        // `diamondInit()` placeholder is the registry itself, so mock the flag there too.
        vm.mockCall(genesisRegistry, abi.encodeWithSelector(IDiamondInit.IS_ZKSYNC_OS.selector), abi.encode(false));
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(ICTMRelease.diamondInit.selector),
            abi.encode(Utils.TEST_GENESIS_REGISTRY)
        );
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(ICTMRelease.genesisFacets.selector),
            abi.encode(new GenesisFacet[](0))
        );
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(ICTMRelease.baseSystemContractHashes.selector),
            abi.encode(
                Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                Utils.TEST_BASE_SYSTEM_CONTRACT_HASH
            )
        );
        // Genesis params the CTM validates in `_setGenesisRegistry` and reads back via
        // `storedBatchZero()` / `l1GenesisUpgrade()`. All non-zero so both Era and ZKsyncOS
        // validation passes; fixtures that actually run the genesis upgrade (i.e. create a chain
        // through the CTM) re-mock `genesisParams` with their real genesis-upgrade address.
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(
                Utils.TEST_GENESIS_REGISTRY, // genesisUpgrade (placeholder non-zero)
                bytes32(uint256(0x01)), // genesisBatchHash
                bytes32(uint256(0x01)), // genesisBatchCommitment
                uint64(0x01) // genesisIndexRepeatedStorageChanges
            )
        );
        // New chains read their force-deployments blob from the registry (empty in fixtures).
        vm.mockCall(
            genesisRegistry,
            abi.encodeWithSelector(ICTMRelease.fixedForceDeploymentsData.selector),
            abi.encode(bytes(""))
        );
    }

    /// @notice Mocks the CTM's protocolVersionVerifier call for DiamondInit
    /// @dev The chainTypeManager address (0x1234567890876543567890) and protocolVersion (0)
    ///      match Utils.TEST_CHAIN_TYPE_MANAGER, which direct-diamond fixtures prank as.
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
