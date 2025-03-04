// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {LegacyBridgeActorHandler} from "../handlers/LegacyBridgeActorHandler.sol";
import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {Token, ActorHandlerAddresses} from "../common/Types.sol";

abstract contract AssetRouter_ActorHandler_Deployer is Test {
    function deployActorHandlers(Token[] memory _tokens) internal returns (ActorHandlerAddresses memory _actorHandlerAddresses) {
        _actorHandlerAddresses.userActorHandlers = new address[](1);
        _actorHandlerAddresses.userActorHandlers[0] = address(new UserActorHandler(_tokens));
        // legacyBridgeActorHandler = new LegacyBridgeActorHandler(userActorHandlers, l1Tokens);
        _actorHandlerAddresses.l1AssetRouterActorHandler = address(new L1AssetRouterActorHandler(_actorHandlerAddresses.userActorHandlers, _tokens));

        for (uint256 i; i < _actorHandlerAddresses.userActorHandlers.length; i++) {
            targetContract(_actorHandlerAddresses.userActorHandlers[i]);
        }
        // targetContract(address(legacyBridgeActorHandler));
        targetContract(_actorHandlerAddresses.l1AssetRouterActorHandler);

        address ts = makeAddr("targetSender");
        deal(ts, 10_000 ether);
        targetSender(ts);
    }
}
