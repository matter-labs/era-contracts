// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1Messenger} from "contracts/common/interfaces/IL1Messenger.sol";

import {AssetRouter_ActorHandler_Deployer} from "../deployers/AssetRouter_ActorHandler_Deployer.sol";
import {AssetRouter_Token_Deployer} from "../deployers/AssetRouter_Token_Deployer.sol";
import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";
import {Token, ActorHandlerAddresses} from "../common/Types.sol";

import {SharedL2ContractL1Deployer} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1Deployer.sol";

contract AssetRouterTest is
    SharedL2ContractL1Deployer,
    AssetRouterProperties,
    AssetRouter_ActorHandler_Deployer,
    AssetRouter_Token_Deployer
{
    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override {
        super.deployL2Contracts(_l1ChainId);

        vm.label(L2_ASSET_ROUTER_ADDR, "L2AssetRouter");
        vm.label(L2_NATIVE_TOKEN_VAULT_ADDR, "L2NativeTokenVault");
        vm.label(address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR), "L1Messenger");

        Token[] memory deployedTokens = _deployTokens();
        ActorHandlerAddresses memory actorHandlerAddresses = deployActorHandlers(deployedTokens);

        assertEq(deployedTokens.length, 6);

        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSelector(IL1Messenger.sendToL1.selector),
            abi.encode(1337)
        );

        initAssetRouterProperties(deployedTokens, actorHandlerAddresses);
    }
}
