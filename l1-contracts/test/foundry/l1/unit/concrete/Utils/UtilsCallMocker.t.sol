// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

// solhint-enable max-line-length

contract UtilsCallMockerTest is Test {
    function mockDiamondInitInteropCenterCalls() public {
        mockDiamondInitInteropCenterCallsWithAddress(address(0x1234567890876543567890), address(0));
    }

    function mockDiamondInitInteropCenterCallsWithAddress(address bridgehub, address assetRouter) public {
        address assetTracker = address(0x1234567890876543567890);
        address nativeTokenVault = address(0x1234567890876543567890);
        if (assetRouter == address(0)) {
            assetRouter = address(0x1234567890876543567890);
        } else if (assetRouter == L2_ASSET_ROUTER_ADDR) {
            nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
            assetTracker = L2_ASSET_TRACKER_ADDR;
        }

        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehub.assetRouter.selector), abi.encode(assetRouter));
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
        bytes32 baseTokenAssetId = bytes32(uint256(uint160(makeAddr("baseTokenAssetId"))));
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVault.originChainId.selector),
            abi.encode(block.chainid)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVault.originToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
    }

    function test() internal virtual {}
}
