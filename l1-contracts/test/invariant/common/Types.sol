// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Token {
    address addr;
    bool bridged;
}

struct ActorHandlerAddresses {
    address[] userActorHandlers;
    address l1AssetRouterActorHandler;
    address l1SharedBridgeActorHandler;
}
