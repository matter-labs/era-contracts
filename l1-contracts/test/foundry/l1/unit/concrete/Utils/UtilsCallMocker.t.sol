// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils.sol";
import {console} from "forge-std/console.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

// solhint-enable max-line-length

contract UtilsCallMockerTest is Test {
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
    }

    function test() internal virtual {}
}
