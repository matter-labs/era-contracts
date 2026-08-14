// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";

import {L1_TOKEN_ADDRESS} from "../common/Constants.sol";

contract UserActorHandler is Test {
    uint256 public ghost_totalWithdrawalAmount;
    uint256 public ghost_totalFunctionCalls;

    function withdraw(uint256 _amount, address _receiver) public {
        address l2Token = L2AssetRouter(L2_ASSET_ROUTER_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        // using `L2NativeTokenVault` instead of `IL2NativeTokenVault` because the latter doesn't have `L2_LEGACY_SHARED_BRIDGE`
        if (
            L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).L2_LEGACY_SHARED_BRIDGE().l1TokenAddress(l2Token) ==
            address(0)
        ) {
            return;
        }

        uint256 balance = BridgedStandardERC20(l2Token).balanceOf(address(this));
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(_amount, 1, balance);

        uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, L1_TOKEN_ADDRESS);
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, _receiver, l2Token);

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.interopBundleSalt,
            (bytes32(ghost_totalFunctionCalls + 1))
        );

        IInteropCenter(L2_INTEROP_CENTER_ADDR).sendBundle(
            InteroperableAddress.formatEvmV1(l1ChainId),
            DataEncoding.encodeInteropWithdrawalCallStarters(assetId, data),
            bundleAttributes
        );

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }
}
