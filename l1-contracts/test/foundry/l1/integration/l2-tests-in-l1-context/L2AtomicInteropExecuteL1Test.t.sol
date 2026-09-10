// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {SharedL2ContractDeployer} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {L2AtomicInteropExecuteTestAbstract} from "../l2-tests-abstract/L2AtomicInteropExecuteTestAbstract.t.sol";

import {SharedL2ContractL1Deployer, SystemContractsArgs} from "./_SharedL2ContractL1Deployer.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract L2AtomicInteropExecuteL1Test is Test, SharedL2ContractL1Deployer, L2AtomicInteropExecuteTestAbstract {
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

    function getInitializeCalldata(
        string memory _contractName
    ) internal virtual override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (bytes memory) {
        return super.getInitializeCalldata(_contractName);
    }

    function _mockAtomicFlowManager() internal override(SharedL2ContractDeployer, L2AtomicInteropExecuteTestAbstract) {
        L2AtomicInteropExecuteTestAbstract._mockAtomicFlowManager();
    }
}
