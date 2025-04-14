// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {AddressHasNoCode} from "./ZkSyncScriptErrors.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IValidatorTimelock} from "./interfaces/IValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IRollupDAManager} from "./interfaces/IRollupDAManager.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {IOwnable} from "./interfaces/IOwnable.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {StateTransitionDeployedAddresses, Utils, FacetCut, Action} from "./Utils.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {DeployUtils, GeneratedData, Config, DeployedAddresses, FixedForceDeploymentsData} from "./DeployUtils.s.sol";

contract DeployL1Script is Script, DeployUtils {
    using stdToml for string;

    function run() public virtual {
        console.log("Deploying L1 contracts");

        runInner("/script-config/config-deploy-l1.toml", "/script-out/output-deploy-l1.toml");
    }

    function runForTest() public {
        runInner(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"));

        // In the production environment, there will be a separate script dedicated to accepting the adminship
        // but for testing purposes we'll have to do it here.
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
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
        deployIfNeededMulticall3();

        addresses.stateTransition.bytecodesSupplier = deploySimpleContract("BytecodesSupplier");

        deployVerifiers();

        (addresses.stateTransition.defaultUpgrade) = deploySimpleContract("DefaultUpgrade");
        (addresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade");
        deployDAValidators();
        (addresses.stateTransition.validatorTimelock) = deploySimpleContract("ValidatorTimelock");

        (addresses.governance) = deploySimpleContract("Governance");
        (addresses.chainAdmin) = deploySimpleContract("ChainAdminOwnable");
        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        addresses.accessControlRestrictionAddress = address(0);

        addresses.transparentProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.governance);
        (addresses.bridgehub.bridgehubImplementation, addresses.bridgehub.bridgehubProxy) = deployTuppWithContract(
            "Bridgehub"
        );
        (addresses.bridgehub.messageRootImplementation, addresses.bridgehub.messageRootProxy) = deployTuppWithContract(
            "MessageRoot"
        );

        (
            addresses.stateTransition.serverNotifierImplementation,
            addresses.stateTransition.serverNotifierProxy
        ) = deployTuppWithContract("ServerNotifier");

        (addresses.bridges.l1NullifierImplementation, addresses.bridges.l1NullifierProxy) = deployTuppWithContract(
            "L1Nullifier"
        );
        (addresses.bridges.l1AssetRouterImplementation, addresses.bridges.l1AssetRouterProxy) = deployTuppWithContract(
            "L1AssetRouter"
        );
        (addresses.bridges.bridgedStandardERC20Implementation) = deploySimpleContract("BridgedStandardERC20");
        addresses.bridges.bridgedTokenBeacon = deployWithCreate2AndOwner("BridgedTokenBeacon", config.ownerAddress);
        (
            addresses.vaults.l1NativeTokenVaultImplementation,
            addresses.vaults.l1NativeTokenVaultProxy
        ) = deployTuppWithContract("L1NativeTokenVault");
        setL1NativeTokenVaultParams();

        (addresses.bridges.erc20BridgeImplementation, addresses.bridges.erc20BridgeProxy) = deployTuppWithContract(
            "L1ERC20Bridge"
        );
        updateSharedBridge();
        // deployChainRegistrar(); // TODO: enable after ChainRegistrar is reviewed
        (
            addresses.bridgehub.ctmDeploymentTrackerImplementation,
            addresses.bridgehub.ctmDeploymentTrackerProxy
        ) = deployTuppWithContract("CTMDeploymentTracker");
        setBridgehubParams();

        initializeGeneratedData();

        addresses.blobVersionedHashRetriever = deploySimpleContract("BlobVersionedHashRetriever");
        deployStateTransitionDiamondFacets();
        (
            addresses.stateTransition.chainTypeManagerImplementation,
            addresses.stateTransition.chainTypeManagerProxy
        ) = deployTuppWithContract("ChainTypeManager");
        registerChainTypeManager();
        setChainTypeManagerInValidatorTimelock();
        setChainTypeManagerInServerNotifier();

        updateOwners();

        saveOutput(outputPath);
    }

    function initializeGeneratedData() internal {
        generatedData.forceDeploymentsData = prepareForceDeploymentsData();
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on public networks
        if (MULTICALL3_ADDRESS.code.length == 0) {
            address contractAddress = deployViaCreate2(type(Multicall3).creationCode, "");
            console.log("Multicall3 deployed at:", contractAddress);
            config.contracts.multicall3Addr = contractAddress;
        } else {
            config.contracts.multicall3Addr = MULTICALL3_ADDRESS;
        }
    }

    function getRollupL2ValidatorAddress() internal returns (address) {
        return
            Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode()),
                hex""
            );
    }

    function getNoDAValidiumL2ValidatorAddress() internal returns (address) {
        return
            Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode()),
                hex""
            );
    }

    function getAvailL2ValidatorAddress() internal returns (address) {
        return
            Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readAvailL2DAValidatorBytecode()),
                hex""
            );
    }

    function deployVerifiers() internal {
        (addresses.stateTransition.verifierFflonk) = deploySimpleContract("VerifierFflonk");
        (addresses.stateTransition.verifierPlonk) = deploySimpleContract("VerifierPlonk");
        (addresses.stateTransition.verifier) = deploySimpleContract("Verifier");
    }

    function setChainTypeManagerInServerNotifier() internal {
        ServerNotifier serverNotifier = ServerNotifier(addresses.stateTransition.serverNotifierProxy);
        vm.broadcast(msg.sender);
        serverNotifier.setChainTypeManager(IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy));
        console.log("ChainTypeManager set in ServerNotifier");
    }

    function deployDAValidators() internal {
        addresses.daAddresses.rollupDAManager = deployWithCreate2AndOwner("RollupDAManager", msg.sender);
        updateRollupDAManager();

        // This contract is located in the `da-contracts` folder, we output it the same way for consistency/ease of use.
        addresses.daAddresses.l1RollupDAValidator = deploySimpleContract("RollupL1DAValidator");

        addresses.daAddresses.noDAValidiumL1DAValidator = deploySimpleContract("ValidiumL1DAValidator");

        if (config.contracts.availL1DAValidator == address(0)) {
            addresses.daAddresses.availBridge = deploySimpleContract("DummyAvailBridge");
            addresses.daAddresses.availL1DAValidator = deploySimpleContract("AvailL1DAValidator");
        } else {
            addresses.daAddresses.availL1DAValidator = config.contracts.availL1DAValidator;
        }
        vm.startBroadcast(msg.sender);
        IRollupDAManager rollupDAManager = IRollupDAManager(addresses.daAddresses.rollupDAManager);
        rollupDAManager.updateDAPair(addresses.daAddresses.l1RollupDAValidator, getRollupL2ValidatorAddress(), true);
        vm.stopBroadcast();
    }

    function updateRollupDAManager() internal virtual {
        IOwnable rollupDAManager = IOwnable(addresses.daAddresses.rollupDAManager);
        if (rollupDAManager.owner() != address(msg.sender)) {
            if (rollupDAManager.pendingOwner() == address(msg.sender)) {
                vm.broadcast(msg.sender);
                rollupDAManager.acceptOwnership();
            } else {
                require(rollupDAManager.owner() == config.ownerAddress, "Ownership was not set correctly");
            }
        }
    }

    function registerChainTypeManager() internal {
        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        console.log("ChainTypeManager registered");
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        sharedBridge.setAssetDeploymentTracker(
            bytes32(uint256(uint160(addresses.stateTransition.chainTypeManagerProxy))),
            address(ctmDT)
        );
        console.log("CTM DT whitelisted");

        ctmDT.registerCTMAssetOnL1(addresses.stateTransition.chainTypeManagerProxy);
        vm.stopBroadcast();
        console.log("CTM registered in CTMDeploymentTracker");

        bytes32 assetId = bridgehub.ctmAssetIdFromAddress(addresses.stateTransition.chainTypeManagerProxy);
        console.log(
            "CTM in router 1",
            sharedBridge.assetHandlerAddress(assetId),
            bridgehub.ctmAssetIdToAddress(assetId)
        );
    }

    function setChainTypeManagerInValidatorTimelock() public virtual {
        IValidatorTimelock validatorTimelock = IValidatorTimelock(addresses.stateTransition.validatorTimelock);
        if (address(validatorTimelock.chainTypeManager()) != addresses.stateTransition.chainTypeManagerProxy) {
            vm.broadcast(msg.sender);
            validatorTimelock.setChainTypeManager(IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy));
        }
        console.log("ChainTypeManager set in ValidatorTimelock");
    }

    function deployDiamondProxy() internal {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: addresses.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });
        address contractAddress = deployViaCreate2(
            type(DiamondProxy).creationCode,
            abi.encode(config.l1ChainId, diamondCut)
        );
        console.log("DiamondProxy deployed at:", contractAddress);
        addresses.stateTransition.diamondProxy = contractAddress;
    }

    function setBridgehubParams() internal {
        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addTokenAssetId(bridgehub.baseTokenAssetId(config.eraChainId));
        bridgehub.setAddresses(
            addresses.bridges.l1AssetRouterProxy,
            ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy),
            IMessageRoot(addresses.bridgehub.messageRootProxy)
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
        sharedBridge.setNativeTokenVault(INativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1AssetRouter(addresses.bridges.l1AssetRouterProxy);

        vm.broadcast(msg.sender);
        IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerEthToken();
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        IValidatorTimelock validatorTimelock = IValidatorTimelock(addresses.stateTransition.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);
        IOwnable(address(bridgehub)).transferOwnership(addresses.governance);
        bridgehub.setPendingAdmin(addresses.chainAdmin);

        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        IOwnable(address(sharedBridge)).transferOwnership(addresses.governance);

        IChainTypeManager ctm = IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        IOwnable(address(ctm)).transferOwnership(addresses.governance);
        ctm.setPendingAdmin(addresses.chainAdmin);

        ICTMDeploymentTracker ctmDeploymentTracker = ICTMDeploymentTracker(
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        IOwnable(address(ctmDeploymentTracker)).transferOwnership(addresses.governance);

        IOwnable(addresses.daAddresses.rollupDAManager).transferOwnership(addresses.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal virtual {
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", addresses.bridgehub.bridgehubProxy);
        vm.serializeAddress("bridgehub", "bridgehub_implementation_addr", addresses.bridgehub.bridgehubImplementation);
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

        // TODO(EVM-744): this has to be renamed to chain type manager
        vm.serializeAddress(
            "state_transition",
            "state_transition_proxy_addr",
            addresses.stateTransition.chainTypeManagerProxy
        );
        vm.serializeAddress(
            "state_transition",
            "state_transition_implementation_addr",
            addresses.stateTransition.chainTypeManagerImplementation
        );
        vm.serializeAddress("state_transition", "verifier_addr", addresses.stateTransition.verifier);
        vm.serializeAddress("state_transition", "admin_facet_addr", addresses.stateTransition.adminFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", addresses.stateTransition.mailboxFacet);
        vm.serializeAddress("state_transition", "executor_facet_addr", addresses.stateTransition.executorFacet);
        vm.serializeAddress("state_transition", "getters_facet_addr", addresses.stateTransition.gettersFacet);
        vm.serializeAddress("state_transition", "diamond_init_addr", addresses.stateTransition.diamondInit);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", addresses.stateTransition.genesisUpgrade);
        vm.serializeAddress("state_transition", "default_upgrade_addr", addresses.stateTransition.defaultUpgrade);
        vm.serializeAddress("state_transition", "bytecodes_supplier_addr", addresses.stateTransition.bytecodesSupplier);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "diamond_proxy_addr",
            addresses.stateTransition.diamondProxy
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

        vm.serializeUint(
            "contracts_config",
            "diamond_init_max_l2_gas_per_batch",
            config.contracts.diamondInitMaxL2GasPerBatch
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_batch_overhead_l1_gas",
            config.contracts.diamondInitBatchOverheadL1Gas
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_max_pubdata_per_batch",
            config.contracts.diamondInitMaxPubdataPerBatch
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_minimal_l2_gas_price",
            config.contracts.diamondInitMinimalL2GasPrice
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_priority_tx_max_pubdata",
            config.contracts.diamondInitPriorityTxMaxPubdata
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_pubdata_pricing_mode",
            uint256(config.contracts.diamondInitPubdataPricingMode)
        );
        vm.serializeUint("contracts_config", "priority_tx_max_gas_limit", config.contracts.priorityTxMaxGasLimit);
        vm.serializeBytes32(
            "contracts_config",
            "recursion_circuits_set_vks_hash",
            config.contracts.recursionCircuitsSetVksHash
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_leaf_level_vk_hash",
            config.contracts.recursionLeafLevelVkHash
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_node_level_vk_hash",
            config.contracts.recursionNodeLevelVkHash
        );
        vm.serializeBytes("contracts_config", "diamond_cut_data", config.contracts.diamondCutData);

        string memory contractsConfig = vm.serializeBytes(
            "contracts_config",
            "force_deployments_data",
            generatedData.forceDeploymentsData
        );

        vm.serializeAddress(
            "deployed_addresses",
            "blob_versioned_hash_retriever_addr",
            addresses.blobVersionedHashRetriever
        );
        vm.serializeAddress(
            "deployed_addresses",
            "server_notifier_proxy_addr",
            addresses.stateTransition.serverNotifierProxy
        );
        vm.serializeAddress(
            "deployed_addresses",
            "server_notifier_implementation_address",
            addresses.stateTransition.serverNotifierImplementation
        );
        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);

        vm.serializeAddress(
            "deployed_addresses",
            "validator_timelock_addr",
            addresses.stateTransition.validatorTimelock
        );
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);
        vm.serializeString("deployed_addresses", "state_transition", stateTransition);

        //vm.serializeAddress("deployed_addresses", "chain_registrar", addresses.chainRegistrar); // TODO: enable after ChainRegistrar is reviewed
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);
        vm.serializeAddress(
            "deployed_addresses",
            "rollup_l1_da_validator_addr",
            addresses.daAddresses.l1RollupDAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "no_da_validium_l1_validator_addr",
            addresses.daAddresses.noDAValidiumL1DAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "avail_l1_da_validator_addr",
            addresses.daAddresses.availL1DAValidator
        );

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            addresses.vaults.l1NativeTokenVaultProxy
        );

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", config.contracts.create2FactorySalt);
        vm.serializeAddress("root", "multicall3_addr", config.contracts.multicall3Addr);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);
        vm.serializeAddress("root", "expected_rollup_l2_da_validator_addr", getRollupL2ValidatorAddress());
        vm.serializeAddress("root", "expected_no_da_validium_l2_validator_addr", getNoDAValidiumL2ValidatorAddress());
        vm.serializeAddress("root", "expected_avail_l2_da_validator_addr", getAvailL2ValidatorAddress());
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    function prepareForceDeploymentsData() internal view returns (bytes memory) {
        require(addresses.governance != address(0), "Governance address is not set");

        address dangerousTestOnlyForcedBeacon;
        if (config.supportL2LegacySharedBridgeTest) {
            (dangerousTestOnlyForcedBeacon, ) = L2LegacySharedBridgeTestHelper.calculateTestL2TokenBeaconAddress(
                addresses.bridges.erc20BridgeProxy,
                addresses.bridges.l1NullifierProxy,
                addresses.governance
            );
        }

        FixedForceDeploymentsData memory data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: addresses.bridges.l1AssetRouterProxy,
            l2TokenProxyBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readBeaconProxyBytecode()
            ),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(addresses.governance),
            maxNumberOfZKChains: config.contracts.maxNumberOfChains,
            bridgehubBytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readBridgehubBytecode()),
            l2AssetRouterBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readL2AssetRouterBytecode()
            ),
            l2NtvBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readL2NativeTokenVaultBytecode()
            ),
            messageRootBytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readMessageRootBytecode()),
            // For newly created chains it it is expected that the following bridges are not present at the moment
            // of creation of the chain
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            dangerousTestOnlyForcedBeacon: dangerousTestOnlyForcedBeacon
        });

        return abi.encode(data);
    }

    function deployTuppWithContract(
        string memory contractName
    ) internal virtual override returns (address implementation, address proxy) {
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            contractName,
            string.concat(contractName, " Implementation")
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, addresses.transparentProxyAdmin, getInitializeCalldata(contractName)),
            contractName,
            string.concat(contractName, " Proxy")
        );
        return (implementation, proxy);
    }

    function saveDiamondSelectors() public {
        AdminFacet adminFacet = new AdminFacet(1, RollupDAManager(address(0)));
        GettersFacet gettersFacet = new GettersFacet();
        MailboxFacet mailboxFacet = new MailboxFacet(1, 1);
        ExecutorFacet executorFacet = new ExecutorFacet(1);
        bytes4[] memory adminFacetSelectors = Utils.getAllSelectors(address(adminFacet).code);
        bytes4[] memory gettersFacetSelectors = Utils.getAllSelectors(address(gettersFacet).code);
        bytes4[] memory mailboxFacetSelectors = Utils.getAllSelectors(address(mailboxFacet).code);
        bytes4[] memory executorFacetSelectors = Utils.getAllSelectors(address(executorFacet).code);

        string memory root = vm.projectRoot();
        string memory outputPath = string.concat(root, "/script-out/diamond-selectors.toml");

        bytes memory adminFacetSelectorsBytes = abi.encode(adminFacetSelectors);
        bytes memory gettersFacetSelectorsBytes = abi.encode(gettersFacetSelectors);
        bytes memory mailboxFacetSelectorsBytes = abi.encode(mailboxFacetSelectors);
        bytes memory executorFacetSelectorsBytes = abi.encode(executorFacetSelectors);

        vm.serializeBytes("diamond_selectors", "admin_facet_selectors", adminFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "getters_facet_selectors", gettersFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "mailbox_facet_selectors", mailboxFacetSelectorsBytes);
        string memory toml = vm.serializeBytes(
            "diamond_selectors",
            "executor_facet_selectors",
            executorFacetSelectorsBytes
        );

        vm.writeToml(toml, outputPath);
    }

    /// @notice Get new facet cuts
    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new FacetCut[](4);
        facetCuts[0] = FacetCut({
            facet: stateTransition.adminFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = FacetCut({
            facet: stateTransition.gettersFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = FacetCut({
            facet: stateTransition.executorFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });
    }

    ////////////////////////////// GetContract data  /////////////////////////////////

    function getCreationCode(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ChainRegistrar")) {
            return type(ChainRegistrar).creationCode;
        } else if (compareStrings(contractName, "Bridgehub")) {
            return type(Bridgehub).creationCode;
        } else if (compareStrings(contractName, "MessageRoot")) {
            return type(MessageRoot).creationCode;
        } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
            return type(CTMDeploymentTracker).creationCode;
        } else if (compareStrings(contractName, "L1Nullifier")) {
            if (config.supportL2LegacySharedBridgeTest) {
                return type(L1NullifierDev).creationCode;
            } else {
                return type(L1Nullifier).creationCode;
            }
        } else if (compareStrings(contractName, "L1AssetRouter")) {
            return type(L1AssetRouter).creationCode;
        } else if (compareStrings(contractName, "L1ERC20Bridge")) {
            return type(L1ERC20Bridge).creationCode;
        } else if (compareStrings(contractName, "L1NativeTokenVault")) {
            return type(L1NativeTokenVault).creationCode;
        } else if (compareStrings(contractName, "BridgedStandardERC20")) {
            return type(BridgedStandardERC20).creationCode;
        } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return type(UpgradeableBeacon).creationCode;
        } else if (compareStrings(contractName, "BlobVersionedHashRetriever")) {
            return hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
        } else if (compareStrings(contractName, "RollupDAManager")) {
            return type(RollupDAManager).creationCode;
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return Utils.readRollupDAValidatorBytecode();
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return type(ValidiumL1DAValidator).creationCode;
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return Utils.readAvailL1DAValidatorBytecode();
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return Utils.readDummyAvailBridgeBytecode();
        } else if (compareStrings(contractName, "Verifier")) {
            if (config.testnetVerifier) {
                return type(TestnetVerifier).creationCode;
            } else {
                return type(DualVerifier).creationCode;
            }
        } else if (compareStrings(contractName, "VerifierFflonk")) {
            return type(L1VerifierFflonk).creationCode;
        } else if (compareStrings(contractName, "VerifierPlonk")) {
            return type(L1VerifierPlonk).creationCode;
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return type(DefaultUpgrade).creationCode;
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return type(L1GenesisUpgrade).creationCode;
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return type(ValidatorTimelock).creationCode;
        } else if (compareStrings(contractName, "Governance")) {
            return type(Governance).creationCode;
        } else if (compareStrings(contractName, "ChainAdminOwnable")) {
            return type(ChainAdminOwnable).creationCode;
        } else if (compareStrings(contractName, "AccessControlRestriction")) {
            // TODO(EVM-924): this function is unused
            return type(AccessControlRestriction).creationCode;
        } else if (compareStrings(contractName, "ChainAdmin")) {
            return type(ChainAdmin).creationCode;
        } else if (compareStrings(contractName, "ChainTypeManager")) {
            return type(ChainTypeManager).creationCode;
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return type(BytecodesSupplier).creationCode;
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return type(ProxyAdmin).creationCode;
        } else if (compareStrings(contractName, "ExecutorFacet")) {
            return type(ExecutorFacet).creationCode;
        } else if (compareStrings(contractName, "AdminFacet")) {
            return type(AdminFacet).creationCode;
        } else if (compareStrings(contractName, "MailboxFacet")) {
            return type(MailboxFacet).creationCode;
        } else if (compareStrings(contractName, "GettersFacet")) {
            return type(GettersFacet).creationCode;
        } else if (compareStrings(contractName, "DiamondInit")) {
            return type(DiamondInit).creationCode;
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return type(ServerNotifier).creationCode;
        } else {
            revert(string.concat("Contract ", contractName, " creation code not set"));
        }
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "Bridgehub")) {
            return abi.encodeCall(Bridgehub.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "MessageRoot")) {
            return abi.encodeCall(MessageRoot.initialize, ());
        } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
            return abi.encodeCall(CTMDeploymentTracker.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "L1Nullifier")) {
            return abi.encodeCall(L1Nullifier.initialize, (config.deployerAddress, 1, 1, 1, 0));
        } else if (compareStrings(contractName, "L1AssetRouter")) {
            return abi.encodeCall(L1AssetRouter.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "L1ERC20Bridge")) {
            return abi.encodeCall(L1ERC20Bridge.initialize, ());
        } else if (compareStrings(contractName, "L1NativeTokenVault")) {
            return
                abi.encodeCall(
                    L1NativeTokenVault.initialize,
                    (config.ownerAddress, addresses.bridges.bridgedTokenBeacon)
                );
        } else if (compareStrings(contractName, "ChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManager.initialize,
                    getChainTypeManagerInitializeData(addresses.stateTransition)
                );
        } else if (compareStrings(contractName, "ChainRegistrar")) {
            return
                abi.encodeCall(
                    ChainRegistrar.initialize,
                    (addresses.bridgehub.bridgehubProxy, config.deployerAddress, config.ownerAddress)
                );
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encodeCall(ServerNotifier.initialize, (msg.sender));
        } else {
            revert(string.concat("Contract ", contractName, " initialize calldata not set"));
        }
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
