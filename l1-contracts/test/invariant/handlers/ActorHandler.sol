// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";

import {Token} from "../common/Types.sol";

abstract contract ActorHandler is Test {
    L2SharedBridgeLegacy l2SharedBridge;
    L2NativeTokenVault l2NativeTokenVault;
    L2AssetRouter l2AssetRouter;

    Token[] public tokens;

    error ArrayIsEmpty();

    constructor(Token[] memory _tokens) {
        if (_tokens.length == 0) {
            revert ArrayIsEmpty();
        }
        for (uint256 i; i < _tokens.length; i++) {
            tokens.push(_tokens[i]);
        }

        l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        l2SharedBridge = L2SharedBridgeLegacy(l2AssetRouter.L2_LEGACY_SHARED_BRIDGE());
    }

    function _getL1TokenAndL2Token(Token memory t) internal view returns (address _l1Token, address _l2Token) {
        if (t.bridged) {
            _l1Token = t.addr;
            _l2Token = l2AssetRouter.l2TokenAddress(_l1Token);
        } else {
            _l2Token = t.addr;
            _l1Token = l2AssetRouter.l1TokenAddress(_l2Token);
        }
    }
}