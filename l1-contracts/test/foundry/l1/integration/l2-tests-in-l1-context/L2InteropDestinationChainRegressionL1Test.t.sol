// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {SharedL2ContractDeployer} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {L2InteropDestinationChainRegressionTestAbstract} from "../l2-tests-abstract/L2InteropDestinationChainRegressionTestAbstract.t.sol";

import {SharedL2ContractL1Deployer, SystemContractsArgs} from "./_SharedL2ContractL1Deployer.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @title L2InteropDestinationChainRegressionL1Test
/// @notice L1 context test for unregistered destination chain check regression (PR #1811)
/// @dev Tests that InteropCenter properly rejects bundles sent to unregistered destination chains
///      to prevent underflow in GWAssetTracker._increaseAndSaveChainBalance
contract L2InteropDestinationChainRegressionL1Test is
    Test,
    SharedL2ContractL1Deployer,
    L2InteropDestinationChainRegressionTestAbstract
{
    function setUp() public override(SharedL2ContractDeployer, L2InteropDestinationChainRegressionTestAbstract) {
        L2InteropDestinationChainRegressionTestAbstract.setUp();
    }

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

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (bytes memory) {
        return super.getInitializeCalldata(contractName, isZKBytecode);
    }
}
