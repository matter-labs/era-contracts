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

contract UserActorHandler is Test {
    address[] public l1Tokens;

    uint256 public ghost_totalWithdrawalAmount;
    uint256 public ghost_totalFunctionCalls;

    error ArrayIsEmpty();

    constructor(address[] memory _l1Tokens) {
        if (_l1Tokens.length == 0) {
            revert ArrayIsEmpty();
        }
        l1Tokens = _l1Tokens;
    }

    function withdraw(uint256 _amount, address _receiver, uint256 _l1TokenIndex) public {
        uint256 l1TokenIndex = bound(_l1TokenIndex, 0, l1Tokens.length - 1);

        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        address l1Token = l1Tokens[l1TokenIndex];
        address l2Token = l2AssetRouter.l2TokenAddress(l1Token);

        // without bounding the amount the handler usually tries to withdraw more than it has causing reverts
        // on the other hand we do want to test for "withdraw more than one has" cases
        // by bounding the amount for _some_ withdrawals we balance between having too many useless reverts
        // and testing too few cases
        uint256 amount;
        if (ghost_totalFunctionCalls % 10 == 0 && false) {
            amount = _amount;
        } else {
            vm.assume(l2Token.code.length != 0);
            amount = bound(_amount, 0, BridgedStandardERC20(l2Token).balanceOf(address(this)));
        }

        // too many reverts (around 50%) without this condition
        vm.assume(amount != 0);
        // using `L2NativeTokenVault` instead of `IL2NativeTokenVault` because the latter doesn't have `L2_LEGACY_SHARED_BRIDGE`
        vm.assume(L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).L2_LEGACY_SHARED_BRIDGE().l1TokenAddress(l2Token) != address(0));


        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, _receiver, l2Token);

        l2AssetRouter.withdraw(assetId, data);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }
}
