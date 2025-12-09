// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {BridgehubBase} from "contracts/core/bridgehub/BridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1AssetTracker, L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {L2DACommitmentScheme, ROLLUP_L2_DA_COMMITMENT_SCHEME} from "contracts/common/Config.sol";

import {Config, CoreDeployedAddresses, DeployL1CoreUtils} from "./DeployL1CoreUtils.s.sol";

contract DeployL1CoreContractsScript is Script, DeployL1CoreUtils {
    using stdToml for string;

    function run() public virtual {
        console.log("Deploying L1 core contracts");

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

    function getAddresses() public view returns (CoreDeployedAddresses memory) {
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
        (
            addresses.bridgehub.assetTrackerImplementation,
            addresses.bridgehub.assetTrackerProxy
        ) = deployTuppWithContract("L1AssetTracker", false);
        updateSharedBridge();
        (
            addresses.bridgehub.ctmDeploymentTrackerImplementation,
            addresses.bridgehub.ctmDeploymentTrackerProxy
        ) = deployTuppWithContract("CTMDeploymentTracker", false);

        (
            addresses.bridgehub.chainAssetHandlerImplementation,
            addresses.bridgehub.chainAssetHandlerProxy
        ) = deployTuppWithContract("L1ChainAssetHandler", false);
        (
            addresses.bridgehub.chainRegistrationSenderImplementation,
            addresses.bridgehub.chainRegistrationSenderProxy
        ) = deployTuppWithContract("ChainRegistrationSender", false);
        setBridgehubParams();

        updateOwners();

        saveOutput(outputPath);
    }

    function setBridgehubParams() internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub.bridgehubProxy);
        IMessageRoot messageRoot = IMessageRoot(addresses.bridgehub.messageRootProxy);
        IL1AssetTracker assetTracker = L1AssetTracker(addresses.bridgehub.assetTrackerProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addTokenAssetId(bridgehub.baseTokenAssetId(config.eraChainId));
        BridgehubBase(address(bridgehub)).setAddresses(
            addresses.bridges.l1AssetRouterProxy,
            ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy),
            IMessageRoot(addresses.bridgehub.messageRootProxy),
            addresses.bridgehub.chainAssetHandlerProxy,
            addresses.bridgehub.chainRegistrationSenderProxy
        );
        assetTracker.setAddresses();
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function updateSharedBridge() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(IL1ERC20Bridge(addresses.bridges.erc20BridgeProxy));
        console.log("SharedBridge updated with ERC20Bridge address");

        L1NativeTokenVault ntv = L1NativeTokenVault(payable(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        ntv.setAssetTracker(addresses.bridgehub.assetTrackerProxy);
        console.log("L1NativeTokenVault updated with AssetTracker address");

        vm.broadcast(msg.sender);
        IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerEthToken();
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
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub.bridgehubProxy);
        IOwnable(address(bridgehub)).transferOwnership(addresses.governance);
        bridgehub.setPendingAdmin(addresses.chainAdmin);

        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        IOwnable(address(sharedBridge)).transferOwnership(addresses.governance);

        IL1AssetTracker assetTracker = IL1AssetTracker(addresses.bridgehub.assetTrackerProxy);
        IOwnable(address(assetTracker)).transferOwnership(addresses.governance);

        L1NativeTokenVault l1NativeTokenVault = L1NativeTokenVault(payable(addresses.vaults.l1NativeTokenVaultProxy));
        l1NativeTokenVault.transferOwnership(config.ownerAddress);

        ICTMDeploymentTracker ctmDeploymentTracker = ICTMDeploymentTracker(
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        IOwnable(address(ctmDeploymentTracker)).transferOwnership(addresses.governance);

        IOwnable(addresses.bridgehub.chainAssetHandlerProxy).transferOwnership(addresses.governance);

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
            "chain_registration_sender_proxy_addr",
            addresses.bridgehub.chainRegistrationSenderProxy
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_registration_sender_implementation_addr",
            addresses.bridgehub.chainRegistrationSenderImplementation
        );
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
        vm.serializeAddress("bridgehub", "chain_asset_handler_proxy_addr", addresses.bridgehub.chainAssetHandlerProxy);
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            addresses.bridgehub.chainAssetHandlerImplementation
        );
        vm.serializeAddress(
            "bridgehub",
            "l1_asset_tracker_implementation_addr",
            addresses.bridgehub.assetTrackerImplementation
        );
        vm.serializeAddress("bridgehub", "l1_asset_tracker_proxy_addr", addresses.bridgehub.assetTrackerProxy);
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

        vm.serializeAddress("contracts", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        string memory contracts = vm.serializeBytes32(
            "contracts",
            "create2_factory_salt",
            create2FactoryParams.factorySalt
        );

        vm.serializeString("root", "contracts", contracts);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    /// todo create permanentValues toml here.
    // function preparePermanentValues() internal {
    //     string memory root = vm.projectRoot();
    //     string memory permanentValuesInputPath = string.concat(root, PERMANENT_VALUES_INPUT);
    //     string memory outputDeployL1Toml = vm.readFile(string.concat(root, ECOSYSTEM_INPUT));
    //     string memory outputDeployCTMToml = vm.readFile(string.concat(root, CTM_INPUT));

    //     bytes32 create2FactorySalt = outputDeployL1Toml.readBytes32("$.contracts.create2_factory_salt");
    //     address create2FactoryAddr;
    //     if (vm.keyExistsToml(outputDeployL1Toml, "$.contracts.create2_factory_addr")) {
    //         create2FactoryAddr = outputDeployL1Toml.readAddress("$.contracts.create2_factory_addr");
    //     }
    //     address ctm = outputDeployCTMToml.readAddress(
    //         "$.deployed_addresses.state_transition.state_transition_proxy_addr"
    //     );
    //     address bytecodesSupplier = outputDeployCTMToml.readAddress(
    //         "$.deployed_addresses.state_transition.bytecodes_supplier_addr"
    //     );
    //     address l1Bridgehub = outputDeployL1Toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
    //     address rollupDAManager = outputDeployCTMToml.readAddress("$.deployed_addresses.l1_rollup_da_manager");
    //     uint256 eraChainId = outputDeployL1Toml.readUint("$.era_chain_id");

    //     vm.serializeString("contracts", "create2_factory_salt", vm.toString(create2FactorySalt));
    //     vm.serializeAddress("contracts", "create2_factory_addr", create2FactoryAddr);
    //     vm.serializeAddress("contracts", "ctm_proxy_address", ctm);
    //     vm.serializeAddress("contracts", "bridgehub_proxy_address", l1Bridgehub);
    //     vm.serializeAddress("contracts", "rollup_da_manager", rollupDAManager);
    //     string memory contracts = vm.serializeAddress("contracts", "l1_bytecodes_supplier_addr", bytecodesSupplier);
    //     vm.serializeString("root", "contracts", contracts);
    //     string memory permanentValuesToml = vm.serializeUint("root", "era_chain_id", eraChainId);
    //     vm.writeToml(permanentValuesToml, permanentValuesInputPath);
    // }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
