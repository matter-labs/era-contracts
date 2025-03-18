// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
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

        // without bounding the amount the handler usually tries to withdraw more than it has causing reverts
        // on the other hand we do want to test for "withdraw more than one has" cases
        // by bounding the amount for _some_ withdrawals we balance between having too many useless reverts
        // and testing too few cases
        uint256 amount;
        if (ghost_totalFunctionCalls % 10 == 0) {
            amount = _amount;
        } else {
            amount = bound(_amount, 0, BridgedStandardERC20(l2Token).balanceOf(address(this)));
        }
        // too many reverts (around 50%) without this condition
        if (amount == 0) {
            return;
        }

        uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, L1_TOKEN_ADDRESS);
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, _receiver, l2Token);

        L2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(assetId, data);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }
}
