// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
// import "forge-std/console.sol";

import {SystemContractsArgs} from "./L2Utils.sol";

import {L2NativeTokenVaultTestAbstract} from "../../l1/integration/l2-tests-abstract/L2NativeTokenVaultTestAbstract.t.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {Create2FactoryUtils} from "deploy-scripts/utils/deploy/Create2FactoryUtils.s.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";
import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";

contract L2NativeTokenVaultTest is Test, SharedL2ContractL2Deployer, L2NativeTokenVaultTestAbstract {
    // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
    // It is a bit easier to use EOA and it is sufficient for the tests.
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {}

    function getChainCreationParamsConfig(
        string memory _config
    ) internal override(DeployCTMUtils, SharedL2ContractL2Deployer) returns (ChainCreationParamsConfig memory) {
        return SharedL2ContractL2Deployer.getChainCreationParamsConfig(_config);
    }

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(Create2FactoryUtils, SharedL2ContractL2Deployer) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL2Deployer, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        return super.getCreationCode(contractName, false);
    }
}
