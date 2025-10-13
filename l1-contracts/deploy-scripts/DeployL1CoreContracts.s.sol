// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {StateTransitionDeployedAddresses} from "./Utils.sol";

import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {BridgehubBase} from "contracts/bridgehub/BridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {L1ChainAssetHandler} from "contracts/bridgehub/L1ChainAssetHandler.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {L2DACommitmentScheme, ROLLUP_L2_DA_COMMITMENT_SCHEME} from "contracts/common/Config.sol";

import {Config, DeployedAddresses} from "./DeployUtils.s.sol";
import {DeployL1HelperScript} from "./DeployL1HelperScript.s.sol";

contract DeployL1CoreContractsScript is Script, DeployL1HelperScript {
    using stdToml for string;

    function run() public virtual {
        console.log("Deploying L1 contracts");

        runInner("/script-config/config-deploy-l1.toml", "/script-out/output-deploy-l1.toml");
    }

    function runForTest() public {
        runInner(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"));

        // In the production environment, there will be a separate script dedicated to accepting the adminship
        // but for testing purposes we'll have to do it here.
        L1Bridgehub bridgehub = L1Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.broadcast(addresses.chainAdmin);
        bridgehub.acceptAdmin();
    }

    function getAddresses() public view returns (DeployedAddresses memory) {
        return addresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function runInner(string memory inputPath, string memory outputPath) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(inputPath);

        instantiateCreate2Factory();

        (addresses.governance) = deploySimpleContract("Governance", false);
        (addresses.chainAdmin) = deploySimpleContract("ChainAdminOwnable", false);
        addresses.transparentProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.governance, false);

        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        addresses.accessControlRestrictionAddress = address(0);
        (addresses.bridgehub.bridgehubImplementation, addresses.bridgehub.bridgehubProxy) = deployTuppWithContract(
            "L1Bridgehub",
            false
        );
        (addresses.bridgehub.messageRootImplementation, addresses.bridgehub.messageRootProxy) = deployTuppWithContract(
            "L1MessageRoot",
            false
        );

        (addresses.bridges.l1NullifierImplementation, addresses.bridges.l1NullifierProxy) = deployTuppWithContract(
            "L1Nullifier",
            false
        );
        (addresses.bridges.l1AssetRouterImplementation, addresses.bridges.l1AssetRouterProxy) = deployTuppWithContract(
            "L1AssetRouter",
            false
        );
        (addresses.bridges.bridgedStandardERC20Implementation) = deploySimpleContract("BridgedStandardERC20", false);
        addresses.bridges.bridgedTokenBeacon = deployWithCreate2AndOwner(
            "BridgedTokenBeacon",
            config.ownerAddress,
            false
        );
        (
            addresses.vaults.l1NativeTokenVaultImplementation,
            addresses.vaults.l1NativeTokenVaultProxy
        ) = deployTuppWithContract("L1NativeTokenVault", false);
        setL1NativeTokenVaultParams();

        (addresses.bridges.erc20BridgeImplementation, addresses.bridges.erc20BridgeProxy) = deployTuppWithContract(
            "L1ERC20Bridge",
            false
        );
        updateSharedBridge();
        (
            addresses.bridgehub.ctmDeploymentTrackerImplementation,
            addresses.bridgehub.ctmDeploymentTrackerProxy
        ) = deployTuppWithContract("CTMDeploymentTracker", false);

        (
            addresses.bridgehub.chainAssetHandlerImplementation,
            addresses.bridgehub.chainAssetHandlerProxy
        ) = deployTuppWithContract("L1ChainAssetHandler", false);
        setBridgehubParams();

        updateOwners();

        saveOutput(outputPath);
    }

    function setBridgehubParams() internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addTokenAssetId(bridgehub.baseTokenAssetId(config.eraChainId));
        BridgehubBase(address(bridgehub)).setAddresses(
            addresses.bridges.l1AssetRouterProxy,
            ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy),
            IMessageRoot(addresses.bridgehub.messageRootProxy),
            addresses.bridgehub.chainAssetHandlerProxy
        );
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function updateSharedBridge() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(IL1ERC20Bridge(addresses.bridges.erc20BridgeProxy));
        console.log("SharedBridge updated with ERC20Bridge address");
    }

    function setL1NativeTokenVaultParams() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        IL1Nullifier l1Nullifier = IL1Nullifier(addresses.bridges.l1NullifierProxy);
        // Ownable ownable = Ownable(addresses.bridges.l1AssetRouterProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setNativeTokenVault(INativeTokenVaultBase(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1AssetRouter(addresses.bridges.l1AssetRouterProxy);

        vm.broadcast(msg.sender);
        IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerEthToken();
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub.bridgehubProxy);
        IOwnable(address(bridgehub)).transferOwnership(addresses.governance);
        bridgehub.setPendingAdmin(addresses.chainAdmin);

        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        IOwnable(address(sharedBridge)).transferOwnership(addresses.governance);

        ICTMDeploymentTracker ctmDeploymentTracker = ICTMDeploymentTracker(
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        IOwnable(address(ctmDeploymentTracker)).transferOwnership(addresses.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal virtual {
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", addresses.bridgehub.bridgehubProxy);
        vm.serializeAddress("bridgehub", "bridgehub_implementation_addr", addresses.bridgehub.bridgehubImplementation);
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            addresses.bridgehub.chainAssetHandlerImplementation
        );
        vm.serializeAddress("bridgehub", "chain_asset_handler_proxy_addr", addresses.bridgehub.chainAssetHandlerProxy);
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            addresses.bridgehub.ctmDeploymentTrackerImplementation
        );
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", addresses.bridgehub.messageRootProxy);
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            addresses.bridgehub.messageRootImplementation
        );

        vm.serializeAddress("bridges", "erc20_bridge_implementation_addr", addresses.bridges.erc20BridgeImplementation);
        vm.serializeAddress("bridges", "erc20_bridge_proxy_addr", addresses.bridges.erc20BridgeProxy);
        vm.serializeAddress("bridges", "l1_nullifier_implementation_addr", addresses.bridges.l1NullifierImplementation);
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", addresses.bridges.l1NullifierProxy);
        vm.serializeAddress(
            "bridges",
            "shared_bridge_implementation_addr",
            addresses.bridges.l1AssetRouterImplementation
        );
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            addresses.bridges.l1AssetRouterProxy
        );

        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            addresses.vaults.l1NativeTokenVaultProxy
        );

        vm.serializeAddress("root", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        vm.serializeBytes32("root", "create2_factory_salt", create2FactoryParams.factorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    /// @notice Get all four facet cuts
    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        // We still want to reuse DeployUtils, but this function is not used in this script
        revert("not implemented");
    }

    /// @notice Get new facet cuts that were added in the upgrade
    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        // We still want to reuse DeployUtils, but this function is not used in this script
        revert("not implemented");
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
