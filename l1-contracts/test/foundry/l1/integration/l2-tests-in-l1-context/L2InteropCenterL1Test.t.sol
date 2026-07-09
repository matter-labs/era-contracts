// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {SharedL2ContractDeployer} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {L2InteropCenterTestAbstract} from "../l2-tests-abstract/L2InteropCenterTestAbstract.t.sol";
import {L2InteropTestUtils} from "../l2-tests-abstract/L2InteropTestUtils.sol";

import {SharedL2ContractL1Deployer, SystemContractsArgs} from "./_SharedL2ContractL1Deployer.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract L2InteropCenterL1Test is Test, SharedL2ContractL1Deployer, L2InteropCenterTestAbstract {
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {}

    /// @dev Route setUp through {L2InteropTestUtils} so the atomic-interop AtomicFlowManager mocks are
    /// installed (see {L2InteropTestUtils.setUp}), then on through the deployer chain.
    function setUp() public virtual override(SharedL2ContractDeployer, L2InteropTestUtils) {
        L2InteropTestUtils.setUp();
    }

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
