// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2Utils} from "test/foundry/l2/integration/L2Utils.sol";

import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {AssetRouter_ActorHandler_Deployer} from "../deployers/AssetRouter_ActorHandler_Deployer.sol";
import {AssetRouter_Token_Deployer} from "../deployers/AssetRouter_Token_Deployer.sol";
import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";

import {SharedL2ContractL1DeployerUtils, SystemContractsArgs} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {SharedL2ContractDeployer} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

contract AssetRouterTest is
    Test,
    SharedL2ContractL1DeployerUtils,
    SharedL2ContractDeployer,
    AssetRouterProperties,
    AssetRouter_ActorHandler_Deployer,
    AssetRouter_Token_Deployer
{
    function test() internal virtual override(DeployUtils, SharedL2ContractL1DeployerUtils) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1DeployerUtils) {
        super.initSystemContracts(_args);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override(SharedL2ContractDeployer, SharedL2ContractL1DeployerUtils) {
        super.deployL2Contracts(_l1ChainId);

        address[] memory deployedL1Tokens = _deployTokens();
        deployActorHandlers(deployedL1Tokens);

        assertEq(l1Tokens.length, 3);
    }
}
