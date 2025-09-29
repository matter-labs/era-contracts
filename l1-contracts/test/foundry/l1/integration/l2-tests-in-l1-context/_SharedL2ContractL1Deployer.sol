// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {Config, DeployUtils, DeployedAddresses} from "../../../../../deploy-scripts/DeployUtils.s.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {StateTransitionDeployedAddresses} from "deploy-scripts/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {DeployCTMIntegrationScript} from "../deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {L2UtilsBase} from "./L2UtilsBase.sol";

import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";

import {DeployL1HelperScript} from "deploy-scripts/DeployL1HelperScript.s.sol";

contract SharedL2ContractL1Deployer is SharedL2ContractDeployer, DeployCTMIntegrationScript {
    using stdToml for string;
    using stdStorage for StdStorage;

    /// @dev We provide a fast form of debugging the L2 contracts using L1 foundry. We also test using zk foundry.

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2UtilsBase.initSystemContracts(_args);
    }

    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        deployL2ContractsInner(_l1ChainId, false);
    }

    function deployL2ContractsInner(uint256 _l1ChainId, bool _skip) public {
        string memory root = vm.projectRoot();
        string memory CONTRACTS_PATH = vm.envString("CONTRACTS_PATH");
        string memory inputPath = string.concat(
            root,
            "/",
            CONTRACTS_PATH,
            "/l1-contracts",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml"
        );
        initializeConfig(inputPath);
        addresses.transparentProxyAdmin = address(0x1);
        addresses.bridgehub.bridgehubProxy = L2_BRIDGEHUB_ADDR;
        addresses.bridgehub.interopCenterProxy = L2_INTEROP_CENTER_ADDR;
        addresses.bridges.l1AssetRouterProxy = L2_ASSET_ROUTER_ADDR;
        addresses.vaults.l1NativeTokenVaultProxy = L2_NATIVE_TOKEN_VAULT_ADDR;
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        if (!_skip) {
            instantiateCreate2Factory();
        }

        addresses.stateTransition.genesisUpgrade = deploySimpleContract("L1GenesisUpgrade", true);
        addresses.stateTransition.verifier = deploySimpleContract("Verifier", true);
        addresses.stateTransition.validatorTimelock = deploySimpleContract("ValidatorTimelock", true);
        deployStateTransitionDiamondFacets();
        (
            addresses.stateTransition.chainTypeManagerImplementation,
            addresses.stateTransition.chainTypeManagerProxy
        ) = deployTuppWithContract("ChainTypeManager", true);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override(DeployCTMIntegrationScript, SharedL2ContractDeployer) {}

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override(DeployUtils, DeployL1HelperScript) returns (bytes memory) {
        return super.getCreationCode(contractName, false);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override(DeployIntegrationUtils, DeployL1HelperScript) returns (bytes memory) {
        return super.getInitializeCalldata(contractName, isZKBytecode);
    }

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    )
        internal
        virtual
        override(DeployCTMIntegrationScript, DeployIntegrationUtils)
        returns (Diamond.FacetCut[] memory)
    {
        return super.getChainCreationFacetCuts(stateTransition);
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    )
        internal
        virtual
        override(DeployCTMIntegrationScript, DeployIntegrationUtils)
        returns (Diamond.FacetCut[] memory)
    {
        return super.getUpgradeAddedFacetCuts(stateTransition);
    }
}
