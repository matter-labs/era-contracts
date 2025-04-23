// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";
import {SharedL2ContractL1DeployerUtils} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {L2WethTestAbstract} from "../../l1/integration/l2-tests-in-l1-context/L2WethTestAbstract.t.sol";

import {SharedL2ContractL2DeployerUtils, SystemContractsArgs} from "./_SharedL2ContractL2DeployerUtils.sol";

contract WethTest is Test, L2WethTestAbstract, SharedL2ContractL2DeployerUtils {
    function test() internal virtual override(DeployUtils, SharedL2ContractL2DeployerUtils) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2DeployerUtils) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(DeployUtils, SharedL2ContractL2DeployerUtils) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL1DeployerUtils, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }
}
