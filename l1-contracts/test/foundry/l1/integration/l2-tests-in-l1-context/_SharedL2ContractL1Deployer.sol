// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {Bridgehub, IBridgehub} from "../../../../../contracts/bridgehub/Bridgehub.sol";
import {InteropCenter, IInteropCenter} from "../../../../../contracts/bridgehub/InteropCenter.sol";
import {L1AssetRouter} from "../../../../../contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "../../../../../contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "../../../../../contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "../../../../../contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "../../../../../contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "../../../../../contracts/state-transition/IChainTypeManager.sol";
import {DeployedAddresses, Config} from "../../../../../deploy-scripts/DeployUtils.s.sol";

import {DeployUtils} from "../../../../../deploy-scripts/DeployUtils.s.sol";

import {L2_MESSAGE_ROOT_ADDR, L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../../../../contracts/common/l2-helpers/L2ContractAddresses.sol";

import {MessageRoot} from "../../../../../contracts/bridgehub/MessageRoot.sol";
import {L2AssetRouter} from "../../../../../contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "../../../../../contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2NativeTokenVaultDev} from "../../../../../contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {DummyL2L1Messenger} from "../../../../../contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {ETH_TOKEN_ADDRESS} from "../../../../../contracts/common/Config.sol";
import {IMessageRoot} from "../../../../../contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "../../../../../contracts/bridgehub/ICTMDeploymentTracker.sol";

import {SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {L2UtilsBase} from "./L2UtilsBase.sol";
import {StateTransitionDeployedAddresses, FacetCut} from "deploy-scripts/Utils.sol";

import {DeployL1IntegrationScript} from "../deploy-scripts/DeployL1Integration.s.sol";
import {StateTransitionDeployedAddresses, FacetCut, Action} from "deploy-scripts/Utils.sol";

import {SystemContractsArgs} from "./Utils.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {DeployL1IntegrationScript} from "../deploy-scripts/DeployL1Integration.s.sol";
import {DeployL1Script} from "deploy-scripts/DeployL1.s.sol";

contract SharedL2ContractL1Deployer is SharedL2ContractDeployer, DeployL1IntegrationScript {
    using stdToml for string;
    using stdStorage for StdStorage;

    /// @dev We provide a fast form of debugging the L2 contracts using L1 foundry. We also test using zk foundry.
    function initSystemContracts(SystemContractsArgs memory _args) internal virtual {
        L2UtilsBase.initSystemContracts(_args);
    }

    function deployL2Contracts(uint256 _l1ChainId) public virtual {
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
        addresses.blobVersionedHashRetriever = address(0x1);
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        if (!_skip) {
            instantiateCreate2Factory();
        }
        addresses.stateTransition.genesisUpgrade = deploySimpleContract("L1GenesisUpgrade");
        addresses.stateTransition.verifier = deploySimpleContract("Verifier");
        addresses.stateTransition.validatorTimelock = deploySimpleContract("ValidatorTimelock");
        deployStateTransitionDiamondFacets();
        (
            addresses.stateTransition.chainTypeManagerImplementation,
            addresses.stateTransition.chainTypeManagerProxy
        ) = deployTuppWithContract("ChainTypeManager");
    }

    // add this to be excluded from coverage report
    function test() internal virtual override(DeployL1IntegrationScript, SharedL2ContractDeployer) {}

    function getCreationCode(
        string memory contractName
    ) internal view virtual override(DeployUtils, DeployL1Script) returns (bytes memory) {
        return super.getCreationCode(contractName);
    }

    function getInitializeCalldata(
        string memory contractName
    ) internal virtual override(DeployIntegrationUtils, DeployL1Script) returns (bytes memory) {
        return super.getInitializeCalldata(contractName);
    }

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override(DeployL1IntegrationScript, DeployIntegrationUtils) returns (FacetCut[] memory) {
        return super.getFacetCuts(stateTransition);
    }
}
