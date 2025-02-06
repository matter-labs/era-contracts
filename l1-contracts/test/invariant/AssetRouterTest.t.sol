// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

import {L1AssetRouterActorHandler} from "./handlers/L1AssetRouterActorHandler.sol";
import {AssetRouterProperties} from "./AssetRouterProperties.sol";
import {SharedL2ContractL1DeployerUtils} from "../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {SharedL2ContractDeployer} from "../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";
import {SystemContractsArgs} from "../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";

contract AssetRouterTest is Test, SharedL2ContractL1DeployerUtils, SharedL2ContractDeployer, AssetRouterProperties {
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

        h = new L1AssetRouterActorHandler();
        address ts = makeAddr("targetSender");
        deal(ts, 10_000 ether);
        targetContract(address(h));
        targetSender(ts);
        // deposit a unit of token to deploy the L2 token
        h.finalizeDeposit(1, address(1), 1);
    }
}