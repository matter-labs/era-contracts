// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
// import "forge-std/console.sol";

import {SystemContractsArgs} from "./L2Utils.sol";

import {StateTransitionDeployedAddresses, FacetCut} from "deploy-scripts/Utils.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2NativeTokenVaultTestAbstract} from "../../l1/integration/l2-tests-in-l1-context/L2NativeTokenVaultTestAbstract.t.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";
import {DeployIntegrationUtils} from "../../l1/integration/deploy-scripts/DeployIntegrationUtils.s.sol";

contract L2NativeTokenVaultTest is Test, SharedL2ContractL2Deployer, L2NativeTokenVaultTestAbstract {
    // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
    // It is a bit easier to use EOA and it is sufficient for the tests.
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
