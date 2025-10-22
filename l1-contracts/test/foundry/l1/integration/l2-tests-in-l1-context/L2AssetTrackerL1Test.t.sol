// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {SharedL2ContractDeployer} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {DeployUtils} from "deploy-scripts/DeployCTMUtils.s.sol";

import {SharedL2ContractL1Deployer, SystemContractsArgs} from "./_SharedL2ContractL1Deployer.sol";
import {L2AssetTrackerTest} from "../l2-tests-abstract/L2AssetTracker.t.sol";

import {StateTransitionDeployedAddresses} from "deploy-scripts/DeployedAddresses.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract L2AssetTrackerL1Test is Test, SharedL2ContractL1Deployer, L2AssetTrackerTest {
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {
        super.initSystemContracts(_args);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {
        super.deployL2Contracts(_l1ChainId);
    }

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (Diamond.FacetCut[] memory) {
        return super.getChainCreationFacetCuts(stateTransition);
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (Diamond.FacetCut[] memory) {
        return super.getUpgradeAddedFacetCuts(stateTransition);
    }

}
