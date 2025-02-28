// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {LegacyBridgeActorHandler} from "../handlers/LegacyBridgeActorHandler.sol";
import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {L1_TOKEN_ADDRESS} from "../common/Constants.sol";

import {ETH_TOKEN_ADDRESS} from "../../../contracts/common/Config.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";

abstract contract AssetRouter_ActorHandler_Deployer is AssetRouterProperties {
    function deployActorHandlers(address[] memory _l1Tokens) internal {
        for (uint256 i; i < _l1Tokens.length; i++) {
            l1Tokens.push(_l1Tokens[i]);
        }
        l1Tokens.push(L1_TOKEN_ADDRESS);
        l1Tokens.push(ETH_TOKEN_ADDRESS);

        userActorHandlers.push(new UserActorHandler(l1Tokens));
        legacyBridgeActorHandler = new LegacyBridgeActorHandler(userActorHandlers, l1Tokens);
        l1AssetRouterActorHandler = new L1AssetRouterActorHandler(userActorHandlers, l1Tokens);

        for (uint256 i; i < userActorHandlers.length; i++) {
            targetContract(address(userActorHandlers[i]));
        }
        targetContract(address(legacyBridgeActorHandler));
        targetContract(address(l1AssetRouterActorHandler));

        address ts = makeAddr("targetSender");
        deal(ts, 10_000 ether);
        targetSender(ts);
    }
}
