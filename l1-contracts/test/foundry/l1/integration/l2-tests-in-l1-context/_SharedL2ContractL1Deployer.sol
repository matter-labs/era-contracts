// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Config, DeployUtils, DeployedAddresses} from "deploy-scripts/DeployUtils.s.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_ROOT_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L2MessageRoot} from "contracts/bridgehub/L2MessageRoot.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2ChainAssetHandler} from "contracts/bridgehub/L2ChainAssetHandler.sol";
import {L2NativeTokenVaultDev} from "contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {L2MessageVerification} from "../../../../../contracts/bridgehub/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "../../../../../contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";

import {StateTransitionDeployedAddresses} from "deploy-scripts/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {DeployCTMIntegrationScript} from "../deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

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
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        addresses.stateTransition.genesisUpgrade = deploySimpleContract("L1GenesisUpgrade", true);
        addresses.stateTransition.verifier = deploySimpleContract("Verifier", true);
        addresses.stateTransition.validatorTimelock = deploySimpleContract("ValidatorTimelock", true);
        deployStateTransitionDiamondFacets();
        string memory ctmContractName = config.isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        (
            addresses.stateTransition.chainTypeManagerImplementation,
            addresses.stateTransition.chainTypeManagerProxy
        ) = deployTuppWithContract(ctmContractName, true);
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
