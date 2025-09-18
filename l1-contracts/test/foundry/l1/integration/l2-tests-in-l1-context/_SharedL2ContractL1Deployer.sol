// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {Bridgehub, IBridgehub} from "../../../../../contracts/bridgehub/Bridgehub.sol";
import {IInteropCenter, InteropCenter} from "../../../../../contracts/interop/InteropCenter.sol";
import {L1AssetRouter} from "../../../../../contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "../../../../../contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "../../../../../contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "../../../../../contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "../../../../../contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "../../../../../contracts/state-transition/IChainTypeManager.sol";
import {Config, DeployUtils, DeployedAddresses} from "../../../../../deploy-scripts/DeployUtils.s.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_ROOT_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {ChainAssetHandler} from "contracts/bridgehub/ChainAssetHandler.sol";
import {L2NativeTokenVaultDev} from "contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {L2MessageVerification} from "../../../../../contracts/interop/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "../../../../../contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";
import {DummyL2L1Messenger} from "../../../../../contracts/dev-contracts/test/DummyL2L1Messenger.sol";

import {Action, FacetCut, StateTransitionDeployedAddresses} from "deploy-scripts/Utils.sol";

import {DeployCTMIntegrationScript} from "../deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {L2UtilsBase} from "./L2UtilsBase.sol";
import {FacetCut, StateTransitionDeployedAddresses} from "deploy-scripts/Utils.sol";

import {DeployL1IntegrationScript} from "../deploy-scripts/DeployL1Integration.s.sol";

import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {DeployCTMScript} from "deploy-scripts/DeployCTM.s.sol";
import {DeployL1HelperScript} from "deploy-scripts/DeployL1HelperScript.s.sol";
import {L2UtilsBase} from "./L2UtilsBase.sol";

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

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override(DeployCTMIntegrationScript, DeployIntegrationUtils) returns (FacetCut[] memory) {
        return super.getFacetCuts(stateTransition);
    }
}
