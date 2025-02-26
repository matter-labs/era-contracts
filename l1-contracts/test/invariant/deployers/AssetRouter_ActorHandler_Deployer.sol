// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";

abstract contract AssetRouter_ActorHandler_Deployer is AssetRouterProperties {
    function deployActorHandlers() internal {
        userActorHandlers.push(new UserActorHandler());
        l1AssetRouterActorHandler = new L1AssetRouterActorHandler(userActorHandlers);
        for (uint256 i; i < userActorHandlers.length; i++) {
            targetContract(address(userActorHandlers[i]));
        }
        targetContract(address(l1AssetRouterActorHandler));

        address ts = makeAddr("targetSender");
        deal(ts, 10_000 ether);
        targetSender(ts);
    }
}
