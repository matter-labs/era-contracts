// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DeployedAddresses, Config} from "deploy-scripts/DeployUtils.s.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {DeployL1ScriptAbstract} from  "deploy-scripts/DeployL1Abstract.s.sol";

import {L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {L2Utils} from "./L2Utils.sol";
import {SharedL2ContractL1DeployerUtils, SystemContractsArgs} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {DeployL1IntegrationScript} from "../../l1/integration/deploy-scripts/DeployL1Integration.s.sol";


import {StateTransitionDeployedAddresses, FacetCut} from "deploy-scripts/Utils.sol";


contract SharedL2ContractL2DeployerUtils is DeployUtils, DeployL1IntegrationScript {
    using stdToml for string;

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual {
        L2Utils.initSystemContracts(_args);
    }

    // note this is duplicate code, but the inheritance is already complex
    function deployL2Contracts(uint256 _l1ChainId) public virtual {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml"
        );
        initializeConfig(inputPath);
        addresses.transparentProxyAdmin = address(0x1);
        addresses.bridgehub.bridgehubProxy = L2_BRIDGEHUB_ADDR;
        addresses.bridges.l1AssetRouterProxy = L2_ASSET_ROUTER_ADDR;
        addresses.vaults.l1NativeTokenVaultProxy = L2_NATIVE_TOKEN_VAULT_ADDR;
        addresses.blobVersionedHashRetriever = address(0x1);
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        addresses.stateTransition.genesisUpgrade = deploySimpleContract("L1GenesisUpgrade");
        addresses.stateTransition.verifier = deploySimpleContract("Verifier");
        addresses.stateTransition.validatorTimelock = deploySimpleContract("ValidatorTimelock");
        deployStateTransitionDiamondFacets();
        (
            addresses.stateTransition.chainTypeManagerImplementation,
            addresses.stateTransition.chainTypeManagerProxy
        ) = deployTuppWithContract("ChainTypeManager");
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual override returns (address) {
        console.log("Deploying via create2 L2");
        return L2Utils.deployViaCreat2L2(creationCode, constructorArgs, config.contracts.create2FactorySalt);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override(DeployUtils, DeployL1ScriptAbstract) {}

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override(DeployUtils, DeployL1IntegrationScript) returns (FacetCut[] memory) {
        return super.getFacetCuts(stateTransition);
    }

    function getDeployedContractName(
        string memory contractName
    ) internal view virtual override(DeployUtils, DeployL1ScriptAbstract) returns (string memory) {
        return super.getDeployedContractName(contractName);
    }

    function getCreationCode(
        string memory contractName
    ) internal view virtual override(DeployUtils, DeployL1ScriptAbstract) returns (bytes memory) {
        return super.getCreationCode(contractName);
    }

    function getCreationCalldata(
        string memory contractName
    ) internal view virtual override(DeployUtils, DeployL1ScriptAbstract) returns (bytes memory) {
        return super.getCreationCalldata(contractName);
    }

    function getInitializeCalldata(
        string memory contractName
    ) internal virtual override(DeployUtils, DeployL1ScriptAbstract) returns (bytes memory) {
        return super.getInitializeCalldata(contractName);
    }
}
