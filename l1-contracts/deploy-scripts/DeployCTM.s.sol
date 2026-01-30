// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {StateTransitionDeployedAddresses, Utils} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2DACommitmentScheme, ROLLUP_L2_DA_COMMITMENT_SCHEME} from "contracts/common/Config.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IRollupDAManager} from "./interfaces/IRollupDAManager.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {Config, DeployedAddresses, GeneratedData} from "./DeployUtils.s.sol";
import {DeployL1HelperScript} from "./DeployL1HelperScript.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVaultZKOS} from "contracts/bridge/ntv/L2NativeTokenVaultZKOS.sol";
import {L2MessageRoot} from "contracts/bridgehub/L2MessageRoot.sol";
import {L2Bridgehub} from "contracts/bridgehub/L2Bridgehub.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";

import {Utils} from "./Utils.sol";

// TODO: pass this value from zkstack_cli
uint32 constant DEFAULT_ZKSYNC_OS_VERIFIER_VERSION = 6;

contract DeployCTMScript is Script, DeployL1HelperScript {
    using stdToml for string;

    function run() public virtual {
        // Had to leave the function due to scripts that inherit this one, as well as for tests
        return ();
    }

    function runWithBridgehub(address bridgehub, bool reuseGovAndAdmin) public {
        console.log("Deploying CTM related contracts");

        runInner(
            "/script-config/config-deploy-l1.toml",
            "/script-out/output-deploy-l1.toml",
            bridgehub,
            reuseGovAndAdmin
        );
    }

    function runForTest(address bridgehub) public {
        saveDiamondSelectors();
        runInner(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"), bridgehub, false);
    }

    function getAddresses() public view returns (DeployedAddresses memory) {
        return addresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function runInner(
        string memory inputPath,
        string memory outputPath,
        address bridgehub,
        bool reuseGovAndAdmin
    ) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(inputPath);

        instantiateCreate2Factory();

        console.log("Initializing core contracts from BH");
        IL1Bridgehub bridgehubProxy = IL1Bridgehub(bridgehub);
        L1AssetRouter assetRouter = L1AssetRouter(bridgehubProxy.assetRouter());
        address messageRoot = address(bridgehubProxy.messageRoot());
        address l1CtmDeployer = address(bridgehubProxy.l1CtmDeployer());
        address chainAssetHandler = address(bridgehubProxy.chainAssetHandler());
        address nativeTokenVault = address(assetRouter.nativeTokenVault());
        address erc20Bridge = address(assetRouter.legacyBridge());
        address l1Nullifier = address(assetRouter.L1_NULLIFIER());

        addresses.bridgehub.bridgehubProxy = bridgehub;
        addresses.bridgehub.bridgehubImplementation = Utils.getImplementation(bridgehub);
        addresses.bridgehub.ctmDeploymentTrackerProxy = l1CtmDeployer;
        addresses.bridgehub.ctmDeploymentTrackerImplementation = Utils.getImplementation(l1CtmDeployer);
        addresses.bridgehub.messageRootProxy = messageRoot;
        addresses.bridgehub.messageRootImplementation = Utils.getImplementation(messageRoot);
        addresses.bridgehub.chainAssetHandlerProxy = chainAssetHandler;
        addresses.bridgehub.chainAssetHandlerImplementation = Utils.getImplementation(chainAssetHandler);

        // Bridges
        addresses.bridges.erc20BridgeProxy = erc20Bridge;
        addresses.bridges.erc20BridgeImplementation = Utils.getImplementation(erc20Bridge);
        addresses.bridges.l1NullifierProxy = l1Nullifier;
        addresses.bridges.l1NullifierImplementation = Utils.getImplementation(l1Nullifier);
        addresses.bridges.l1AssetRouterProxy = address(assetRouter);
        addresses.bridges.l1AssetRouterImplementation = Utils.getImplementation(address(assetRouter));
        addresses.vaults.l1NativeTokenVaultProxy = nativeTokenVault;

        if (reuseGovAndAdmin) {
            addresses.governance = IOwnable(bridgehub).owner();
            addresses.chainAdmin = bridgehubProxy.admin();
            addresses.transparentProxyAdmin = Utils.getProxyAdminAddress(bridgehub);
        } else {
            (addresses.governance) = deploySimpleContract("Governance", false);
            (addresses.chainAdmin) = deploySimpleContract("ChainAdminOwnable", false);
            addresses.transparentProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.governance, false);
        }

        deployDAValidators();
        deployIfNeededMulticall3();

        addresses.stateTransition.bytecodesSupplier = deploySimpleContract("BytecodesSupplier", false);

        deployVerifiers();

        (addresses.stateTransition.defaultUpgrade) = deploySimpleContract("DefaultUpgrade", false);
        (addresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        addresses.accessControlRestrictionAddress = address(0);

        (, addresses.stateTransition.validatorTimelock) = deployTuppWithContract("ValidatorTimelock", false);

        (
            addresses.stateTransition.serverNotifierImplementation,
            addresses.stateTransition.serverNotifierProxy
        ) = deployServerNotifier();

        initializeGeneratedData();

        deployStateTransitionDiamondFacets();
        string memory ctmContractName = config.isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        (
            addresses.stateTransition.chainTypeManagerImplementation,
            addresses.stateTransition.chainTypeManagerProxy
        ) = deployTuppWithContract(ctmContractName, false);
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

    function getRollupL2DACommitmentScheme() internal returns (L2DACommitmentScheme) {
        return ROLLUP_L2_DA_COMMITMENT_SCHEME;
    }

    function getBlobZKsyncOSCommitmentScheme() internal pure returns (L2DACommitmentScheme) {
        return L2DACommitmentScheme.BLOBS_ZKSYNC_OS;
    }

    function deployVerifiers() internal {
        if (config.isZKsyncOS) {
            (addresses.stateTransition.verifierFflonk) = deploySimpleContract("ZKsyncOSVerifierFflonk", false);
            (addresses.stateTransition.verifierPlonk) = deploySimpleContract("ZKsyncOSVerifierPlonk", false);
        } else {
            (addresses.stateTransition.verifierFflonk) = deploySimpleContract("EraVerifierFflonk", false);
            (addresses.stateTransition.verifierPlonk) = deploySimpleContract("EraVerifierPlonk", false);
        }
        (addresses.stateTransition.verifier) = deploySimpleContract("Verifier", false);

        if (config.isZKsyncOS) {
            // We add the verifier to the default execution version
            vm.startBroadcast(msg.sender);
            ZKsyncOSDualVerifier(addresses.stateTransition.verifier).addVerifier(
                DEFAULT_ZKSYNC_OS_VERIFIER_VERSION,
                IVerifierV2(addresses.stateTransition.verifierFflonk),
                IVerifier(addresses.stateTransition.verifierPlonk)
            );
            ZKsyncOSDualVerifier(addresses.stateTransition.verifier).transferOwnership(config.ownerAddress);
            vm.stopBroadcast();
        }
    }

    function setChainTypeManagerInServerNotifier() internal {
        ServerNotifier serverNotifier = ServerNotifier(addresses.stateTransition.serverNotifierProxy);
        vm.broadcast(msg.sender);
        serverNotifier.setChainTypeManager(IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy));
        console.log("ChainTypeManager set in ServerNotifier");
    }

    function deployDAValidators() internal {
        addresses.daAddresses.rollupDAManager = deployWithCreate2AndOwner("RollupDAManager", msg.sender, false);
        updateRollupDAManager();

        // This contract is located in the `da-contracts` folder, we output it the same way for consistency/ease of use.
        addresses.daAddresses.l1RollupDAValidator = deploySimpleContract("RollupL1DAValidator", false);
        if (config.isZKsyncOS) {
            addresses.daAddresses.l1BlobsDAValidatorZKsyncOS = deploySimpleContract(
                "BlobsL1DAValidatorZKsyncOS",
                false
            );
        }

        addresses.daAddresses.noDAValidiumL1DAValidator = deploySimpleContract("ValidiumL1DAValidator", false);

        if (config.contracts.availL1DAValidator == address(0)) {
            addresses.daAddresses.availBridge = deploySimpleContract("DummyAvailBridge", false);
            addresses.daAddresses.availL1DAValidator = deploySimpleContract("AvailL1DAValidator", false);
        } else {
            addresses.daAddresses.availL1DAValidator = config.contracts.availL1DAValidator;
        }
        vm.startBroadcast(msg.sender);
        IRollupDAManager rollupDAManager = IRollupDAManager(addresses.daAddresses.rollupDAManager);
        rollupDAManager.updateDAPair(addresses.daAddresses.l1RollupDAValidator, getRollupL2DACommitmentScheme(), true);
        if (config.isZKsyncOS) {
            rollupDAManager.updateDAPair(
                addresses.daAddresses.l1BlobsDAValidatorZKsyncOS,
                L2DACommitmentScheme.BLOBS_ZKSYNC_OS,
                true
            );
        }
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

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.stateTransition.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        IChainTypeManager ctm = IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        IOwnable(address(ctm)).transferOwnership(addresses.governance);
        ctm.setPendingAdmin(addresses.chainAdmin);

        IOwnable(addresses.stateTransition.serverNotifierProxy).transferOwnership(addresses.chainAdmin);
        IOwnable(addresses.daAddresses.rollupDAManager).transferOwnership(addresses.governance);

        IOwnable(addresses.daAddresses.rollupDAManager).transferOwnership(addresses.governance);
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
            "server_notifier_proxy_addr",
            addresses.stateTransition.serverNotifierProxy
        );
        vm.serializeAddress(
            "deployed_addresses",
            "server_notifier_implementation_address",
            addresses.stateTransition.serverNotifierImplementation
        );
        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);

        vm.serializeAddress(
            "deployed_addresses",
            "validator_timelock_addr",
            addresses.stateTransition.validatorTimelock
        );
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);
        vm.serializeString("deployed_addresses", "state_transition", stateTransition);

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
        if (config.isZKsyncOS) {
            vm.serializeAddress(
                "deployed_addresses",
                "blobs_zksync_os_l1_da_validator_addr",
                addresses.daAddresses.l1BlobsDAValidatorZKsyncOS
            );
        }
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

        vm.serializeAddress("root", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        vm.serializeBytes32("root", "create2_factory_salt", create2FactoryParams.factorySalt);
        vm.serializeAddress("root", "multicall3_addr", config.contracts.multicall3Addr);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    function prepareForceDeploymentsData() internal returns (bytes memory) {
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
            // TODO: the naming should reflect that it should be only used for Era.
            l2TokenProxyBytecodeHash: getL2BytecodeHash("BeaconProxy"),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(addresses.governance),
            maxNumberOfZKChains: config.contracts.maxNumberOfChains,
            bridgehubBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("L2Bridgehub.sol", "L2Bridgehub")
                : abi.encode(getL2BytecodeHash("L2Bridgehub")),
            l2AssetRouterBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("L2AssetRouter.sol", "L2AssetRouter")
                : abi.encode(getL2BytecodeHash("L2AssetRouter")),
            l2NtvBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("L2NativeTokenVaultZKOS.sol", "L2NativeTokenVaultZKOS")
                : abi.encode(getL2BytecodeHash("L2NativeTokenVault")),
            messageRootBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("L2MessageRoot.sol", "L2MessageRoot")
                : abi.encode(getL2BytecodeHash("L2MessageRoot")),
            beaconDeployerInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("UpgradeableBeaconDeployer.sol", "UpgradeableBeaconDeployer")
                : abi.encode(getL2BytecodeHash("UpgradeableBeaconDeployer")),
            chainAssetHandlerBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("L2ChainAssetHandler.sol", "L2ChainAssetHandler")
                : abi.encode(getL2BytecodeHash("L2ChainAssetHandler")),
            // For newly created chains it it is expected that the following bridges are not present at the moment
            // of creation of the chain
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            dangerousTestOnlyForcedBeacon: dangerousTestOnlyForcedBeacon
        });

        return abi.encode(data);
    }

    function deployServerNotifier() internal returns (address implementation, address proxy) {
        // We will not store the address of the ProxyAdmin as it is trivial to query if needed.
        address ecosystemProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.chainAdmin, false);

        (implementation, proxy) = deployTuppWithContractAndProxyAdmin("ServerNotifier", ecosystemProxyAdmin, false);
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

    /// @notice Get all four facet cuts
    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        // This function is not used in this script
        revert("not implemented");
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
