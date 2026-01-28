// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AssetRouter_ActorHandler_Deployer} from "../deployers/AssetRouter_ActorHandler_Deployer.sol";

import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";
import {SharedL2ContractL2Deployer, SystemContractsArgs} from "../../foundry/l2/integration/_SharedL2ContractL2Deployer.sol";
import {SharedL2ContractL1Deployer} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1Deployer.sol";
import {SharedL2ContractDeployer} from "../../foundry/l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

contract AssetRouterTest is
    Test,
    SharedL2ContractL2Deployer,
    SharedL2ContractDeployer,
    AssetRouterProperties,
    AssetRouter_ActorHandler_Deployer
{
    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {
        super.initSystemContracts(_args);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {
        super.deployL2Contracts(_l1ChainId);
        deployActorHandlers();
    }
}
