// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AssetRouterProperties} from "./AssetRouterProperties.sol";
import {UserActorHandler} from "./UserActorHandler.sol";
import {L1AssetRouterActorHandler} from "./L1AssetRouterActorHandler.sol";

abstract contract AssetRouterActorHandlerDeployer is AssetRouterProperties {
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
