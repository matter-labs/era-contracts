// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Token {
    address addr;
    uint256 chainid;
    address assetDeploymentTrackerAddr;
    bool bridged;
}

struct ActorHandlerAddresses {
    address[] userActorHandlers;
    address l1AssetRouterActorHandler;
    address l1SharedBridgeActorHandler;
}
