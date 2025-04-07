// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

import {StateTransitionDeployedAddresses, FacetCut} from "deploy-scripts/Utils.sol";

import {DeployIntegrationUtils} from "../../l1/integration/deploy-scripts/DeployIntegrationUtils.s.sol";

import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";
import {L2WethTestAbstract} from "../../l1/integration/l2-tests-in-l1-context/L2WethTestAbstract.t.sol";

import {SharedL2ContractL2Deployer, SystemContractsArgs} from "./_SharedL2ContractL2Deployer.sol";

contract WethTest is Test, L2WethTestAbstract, SharedL2ContractL2Deployer {
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(DeployUtils, SharedL2ContractL2Deployer) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL2Deployer, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }
}
