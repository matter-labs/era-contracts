// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AssetRouter_ActorHandler_Deployer} from "../deployers/AssetRouter_ActorHandler_Deployer.sol";
import {AssetRouter_Token_Deployer} from "../deployers/AssetRouter_Token_Deployer.sol";
import {Token, ActorHandlerAddresses} from "../common/Types.sol";

import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";
import {SharedL2ContractL2Deployer} from "../../foundry/l2/integration/_SharedL2ContractL2Deployer.sol";

contract AssetRouterTest is
    SharedL2ContractL2Deployer,
    AssetRouterProperties,
    AssetRouter_ActorHandler_Deployer,
    AssetRouter_Token_Deployer
{
    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        super.deployL2Contracts(_l1ChainId);

        Token[] memory deployedTokens = _deployTokens();
        ActorHandlerAddresses memory actorHandlerAddresses = deployActorHandlers(deployedTokens);

        assertEq(deployedTokens.length, 6);

        initAssetRouterProperties(deployedTokens, actorHandlerAddresses);
    }
}
