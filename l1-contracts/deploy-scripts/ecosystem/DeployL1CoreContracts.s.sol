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
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
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
import {IDeployL1CoreContracts} from "contracts/script-interfaces/IDeployL1CoreContracts.sol";

contract DeployL1CoreContractsScript is Script, DeployL1CoreUtils, IDeployL1CoreContracts {
    using stdToml for string;

    function run() public virtual {
        console.log("Deploying L1 core contracts");

        runInner("/script-config/config-deploy-l1.toml", "/script-out/output-deploy-l1.toml");
    }

    function runForTest() public {
        runInner(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"));

        // In the production environment, there will be a separate script dedicated to accepting the adminship
        // but for testing purposes we'll have to do it here.
        L1Bridgehub bridgehub = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        vm.broadcast(coreAddresses.shared.bridgehubAdmin);
        bridgehub.acceptAdmin();
    }

    function getAddresses() public view returns (CoreDeployedAddresses memory) {
        return coreAddresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function runInner(string memory inputPath, string memory outputPath) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);

        createPermanentValuesIfNeeded();

        initializeConfig(inputPath);

        instantiateCreate2Factory();

        (coreAddresses.shared.governance) = deploySimpleContract("Governance", false);
        (coreAddresses.shared.bridgehubAdmin) = deploySimpleContract("ChainAdminOwnable", false);
        coreAddresses.shared.transparentProxyAdmin = deployWithCreate2AndOwner(
            "ProxyAdmin",
            coreAddresses.shared.governance,
            false
        );

        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        coreAddresses.shared.accessControlRestrictionAddress = address(0);
        (
            coreAddresses.bridgehub.implementations.bridgehub,
            coreAddresses.bridgehub.proxies.bridgehub
        ) = deployTuppWithContract("L1Bridgehub", false);
        (
            coreAddresses.bridgehub.implementations.messageRoot,
            coreAddresses.bridgehub.proxies.messageRoot
        ) = deployTuppWithContract("L1MessageRoot", false);

        (
            coreAddresses.bridges.implementations.l1Nullifier,
            coreAddresses.bridges.proxies.l1Nullifier
        ) = deployTuppWithContract("L1Nullifier", false);
        (
            coreAddresses.bridges.implementations.l1AssetRouter,
            coreAddresses.bridges.proxies.l1AssetRouter
        ) = deployTuppWithContract("L1AssetRouter", false);
        (coreAddresses.bridges.bridgedStandardERC20Implementation) = deploySimpleContract(
            "BridgedStandardERC20",
            false
        );
        coreAddresses.bridges.bridgedTokenBeacon = deployWithCreate2AndOwner(
            "BridgedTokenBeacon",
            config.ownerAddress,
            false
        );
        (
            coreAddresses.bridges.implementations.l1NativeTokenVault,
            coreAddresses.bridges.proxies.l1NativeTokenVault
        ) = deployTuppWithContract("L1NativeTokenVault", false);
        setL1NativeTokenVaultParams();

        (
            coreAddresses.bridges.implementations.erc20Bridge,
            coreAddresses.bridges.proxies.erc20Bridge
        ) = deployTuppWithContract("L1ERC20Bridge", false);
        (
            coreAddresses.bridgehub.implementations.assetTracker,
            coreAddresses.bridgehub.proxies.assetTracker
        ) = deployTuppWithContract("L1AssetTracker", false);
        updateSharedBridge();
        (
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker,
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker
        ) = deployTuppWithContract("CTMDeploymentTracker", false);

        (
            coreAddresses.bridgehub.implementations.chainAssetHandler,
            coreAddresses.bridgehub.proxies.chainAssetHandler
        ) = deployTuppWithContract("L1ChainAssetHandler", false);
        (
            coreAddresses.bridgehub.implementations.chainRegistrationSender,
            coreAddresses.bridgehub.proxies.chainRegistrationSender
        ) = deployTuppWithContract("ChainRegistrationSender", false);
        setBridgehubParams();

        updateOwners();

        saveOutput(outputPath);
        preparePermanentValues(outputPath);
    }

    function setBridgehubParams() internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        IMessageRootBase messageRoot = IMessageRootBase(coreAddresses.bridgehub.proxies.messageRoot);
        IL1AssetTracker assetTracker = L1AssetTracker(coreAddresses.bridgehub.proxies.assetTracker);
        vm.startBroadcast(msg.sender);
        bridgehub.addTokenAssetId(bridgehub.baseTokenAssetId(config.eraChainId));
        BridgehubBase(address(bridgehub)).setAddresses(
            coreAddresses.bridges.proxies.l1AssetRouter,
            ICTMDeploymentTracker(coreAddresses.bridgehub.proxies.ctmDeploymentTracker),
            IMessageRootBase(coreAddresses.bridgehub.proxies.messageRoot),
            coreAddresses.bridgehub.proxies.chainAssetHandler,
            coreAddresses.bridgehub.proxies.chainRegistrationSender
        );
        assetTracker.setAddresses();
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function updateSharedBridge() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(IL1ERC20Bridge(coreAddresses.bridges.proxies.erc20Bridge));
        console.log("SharedBridge updated with ERC20Bridge address");

        L1NativeTokenVault ntv = L1NativeTokenVault(payable(coreAddresses.bridges.proxies.l1NativeTokenVault));
        vm.broadcast(msg.sender);
        ntv.setAssetTracker(coreAddresses.bridgehub.proxies.assetTracker);
        console.log("L1NativeTokenVault updated with AssetTracker address");

        vm.broadcast(msg.sender);
        IL1NativeTokenVault(coreAddresses.bridges.proxies.l1NativeTokenVault).registerEthToken();
    }

    function setL1NativeTokenVaultParams() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        IL1Nullifier l1Nullifier = IL1Nullifier(coreAddresses.bridges.proxies.l1Nullifier);
        // Ownable ownable = Ownable(coreAddresses.bridges.proxies.l1AssetRouter);
        vm.broadcast(msg.sender);
        sharedBridge.setNativeTokenVault(INativeTokenVaultBase(coreAddresses.bridges.proxies.l1NativeTokenVault));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(coreAddresses.bridges.proxies.l1NativeTokenVault));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        IL1Bridgehub bridgehub = IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        IOwnable(address(bridgehub)).transferOwnership(coreAddresses.shared.governance);
        bridgehub.setPendingAdmin(coreAddresses.shared.bridgehubAdmin);

        IL1AssetRouter sharedBridge = IL1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        IOwnable(address(sharedBridge)).transferOwnership(coreAddresses.shared.governance);

        IL1AssetTracker assetTracker = IL1AssetTracker(coreAddresses.bridgehub.proxies.assetTracker);
        IOwnable(address(assetTracker)).transferOwnership(coreAddresses.shared.governance);

        L1NativeTokenVault l1NativeTokenVault = L1NativeTokenVault(
            payable(coreAddresses.bridges.proxies.l1NativeTokenVault)
        );
        l1NativeTokenVault.transferOwnership(config.ownerAddress);

        ICTMDeploymentTracker ctmDeploymentTracker = ICTMDeploymentTracker(
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker
        );
        IOwnable(address(ctmDeploymentTracker)).transferOwnership(coreAddresses.shared.governance);

        IOwnable(coreAddresses.bridgehub.proxies.chainAssetHandler).transferOwnership(coreAddresses.shared.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal virtual {
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", coreAddresses.bridgehub.proxies.bridgehub);
        vm.serializeAddress(
            "bridgehub",
            "bridgehub_implementation_addr",
            coreAddresses.bridgehub.implementations.bridgehub
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_proxy_addr",
            coreAddresses.bridgehub.proxies.chainAssetHandler
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_registration_sender_proxy_addr",
            coreAddresses.bridgehub.proxies.chainRegistrationSender
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_registration_sender_implementation_addr",
            coreAddresses.bridgehub.implementations.chainRegistrationSender
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_proxy_addr",
            coreAddresses.bridgehub.proxies.chainAssetHandler
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
        vm.serializeAddress(
            "bridgehub",
            "l1_asset_tracker_implementation_addr",
            coreAddresses.bridgehub.implementations.assetTracker
        );
        vm.serializeAddress("bridgehub", "l1_asset_tracker_proxy_addr", coreAddresses.bridgehub.proxies.assetTracker);
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", coreAddresses.bridgehub.proxies.messageRoot);
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            coreAddresses.bridgehub.implementations.messageRoot
        );

        vm.serializeAddress(
            "bridges",
            "erc20_bridge_implementation_addr",
            coreAddresses.bridges.implementations.erc20Bridge
        );
        vm.serializeAddress("bridges", "erc20_bridge_proxy_addr", coreAddresses.bridges.proxies.erc20Bridge);
        vm.serializeAddress(
            "bridges",
            "l1_nullifier_implementation_addr",
            coreAddresses.bridges.implementations.l1Nullifier
        );
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", coreAddresses.bridges.proxies.l1Nullifier);
        vm.serializeAddress(
            "bridges",
            "shared_bridge_implementation_addr",
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            coreAddresses.bridges.proxies.l1AssetRouter
        );

        vm.serializeAddress("deployed_addresses", "governance_addr", coreAddresses.shared.governance);
        vm.serializeAddress(
            "deployed_addresses",
            "transparent_proxy_admin_addr",
            coreAddresses.shared.transparentProxyAdmin
        );
        vm.serializeAddress("deployed_addresses", "chain_admin", coreAddresses.shared.bridgehubAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            coreAddresses.shared.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            coreAddresses.bridges.proxies.l1NativeTokenVault
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

        (address create2FactoryAddr, bytes32 create2FactorySalt) = getCreate2FactoryParams();
        savePermanentValues(create2FactorySalt, create2FactoryAddr);
    }

    function createPermanentValuesIfNeeded() internal virtual {
        // Determine the permanent values path
        string memory permanentValuesPath = getPermanentValuesPath();
        if (!vm.isFile(permanentValuesPath)) {
            savePermanentValues(hex"88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5", address(0));
        } else {
            string memory permanentValuesToml = vm.readFile(permanentValuesPath);
            if (!vm.keyExistsToml(permanentValuesToml, "$.permanent_contracts.create2_factory_salt")) {
                savePermanentValues(hex"88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5", address(0));
            }
        }
        (address create2FactoryAddr, ) = getPermanentValues(getPermanentValuesPath());
        if (create2FactoryAddr.code.length == 0) {
            savePermanentValues(hex"88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5", address(0));
        }
    }

    function savePermanentValues(bytes32 create2FactorySalt, address create2FactoryAddr) internal virtual {
        // Determine the permanent values path
        string memory permanentValuesPath = getPermanentValuesPath();

        // Create file if it doesn't exist
        if (!vm.isFile(permanentValuesPath)) {
            vm.writeFile(permanentValuesPath, "[contracts]\n");
        }

        vm.serializeString("permanent_contracts", "create2_factory_salt", vm.toString(create2FactorySalt));
        string memory permanentContracts = vm.serializeAddress(
            "permanent_contracts",
            "create2_factory_addr",
            create2FactoryAddr
        );
        string memory toml1 = vm.serializeString("root3", "permanent_contracts", permanentContracts);

        vm.writeToml(toml1, permanentValuesPath);
        console.log("Updated permanent values at:", permanentValuesPath);
        console.log("create2_factory_addr:", create2FactoryAddr);
    }

    function preparePermanentValues(string memory outputPath) internal virtual {
        // Read from the output file we just created
        string memory outputDeployL1Toml = vm.readFile(outputPath);

        address create2FactoryAddr;
        bytes32 create2FactorySalt;
        if (vm.keyExistsToml(outputDeployL1Toml, "$.permanent_contracts.create2_factory_addr")) {
            create2FactoryAddr = outputDeployL1Toml.readAddress("$.permanent_contracts.create2_factory_addr");
            create2FactorySalt = outputDeployL1Toml.readBytes32("$.permanent_contracts.create2_factory_salt");
        }

        // Only update if create2FactoryAddr is non-zero
        if (create2FactoryAddr != address(0)) {
            savePermanentValues(create2FactorySalt, create2FactoryAddr);
        }
    }

    function getPermanentValuesPath() internal view virtual returns (string memory) {
        string memory root = vm.projectRoot();
        return string.concat(root, vm.envString("PERMANENT_VALUES_INPUT"));
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
