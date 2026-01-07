// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {StateTransitionDeployedAddresses} from "../utils/Types.sol";
import {Utils} from "../utils/Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IRollupDAManager} from "../interfaces/IRollupDAManager.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {L2LegacySharedBridgeTestHelper} from "../dev/L2LegacySharedBridgeTestHelper.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {Config, CTMDeployedAddresses, DeployCTMUtils} from "./DeployCTMUtils.s.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

// TODO: pass this value from zkstack_cli
uint32 constant DEFAULT_ZKSYNC_OS_VERIFIER_VERSION = 6;

contract DeployCTMScript is Script, DeployCTMUtils {
    using stdToml for string;

    function run() public virtual {
        // Had to leave the function due to scripts that inherit this one, as well as for tests
        return ();
    }

    function runWithBridgehub(address bridgehub, bool reuseGovAndAdmin) public {
        console.log("Deploying CTM related contracts");

        runInner(
            "/script-config/permanent-values.toml",
            "/script-config/config-deploy-ctm.toml",
            "/script-out/output-deploy-ctm.toml",
            bridgehub,
            reuseGovAndAdmin,
            false
        );
    }

    function runForTest(address bridgehub, bool skipL1Deployments) public {
        saveDiamondSelectors();
        runInner(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("CTM_CONFIG"),
            vm.envString("CTM_OUTPUT"),
            bridgehub,
            false,
            skipL1Deployments
        );
    }

    function getAddresses() public view virtual returns (CTMDeployedAddresses memory) {
        return addresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function runInner(
        string memory permanentValuesInputPath,
        string memory inputPath,
        string memory outputPath,
        address bridgehub,
        bool reuseGovAndAdmin,
        bool skipL1Deployments
    ) internal {
        string memory root = vm.projectRoot();
        permanentValuesInputPath = string.concat(root, permanentValuesInputPath);
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(inputPath);

        if (!skipL1Deployments) {
            instantiateCreate2Factory();
        }

        console.log("Initializing core contracts from BH");
        IL1Bridgehub bridgehubProxy = IL1Bridgehub(bridgehub);
        // Populate discovered addresses via inspector
        discoveredBridgehub = AddressIntrospector.getBridgehubAddresses(bridgehubProxy);
        config.eraChainId = AddressIntrospector.getEraChainId(discoveredBridgehub.assetRouter);

        if (reuseGovAndAdmin) {
            addresses.governance = discoveredBridgehub.governance;
            addresses.chainAdmin = discoveredBridgehub.admin;
            addresses.transparentProxyAdmin = discoveredBridgehub.transparentProxyAdmin;
        } else {
            (addresses.governance) = deploySimpleContract("Governance", false);
            (addresses.chainAdmin) = deploySimpleContract("ChainAdminOwnable", false);
            addresses.transparentProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.governance, false);
        }

        deployEIP7702Checker();
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

    function deployEIP7702Checker() internal {
        addresses.eip7702Checker = deploySimpleContract("EIP7702Checker", false);
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
                getRollupL2DACommitmentScheme(),
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

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.stateTransition.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        IChainTypeManager ctm = IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        IOwnable(address(ctm)).transferOwnership(addresses.governance);
        ctm.setPendingAdmin(addresses.chainAdmin);

        IOwnable(addresses.stateTransition.serverNotifierProxy).transferOwnership(addresses.chainAdmin);
        IOwnable(addresses.daAddresses.rollupDAManager).transferOwnership(addresses.governance);

        if (config.isZKsyncOS) {
            // We need to transfer the ownership of the Verifier
            ZKsyncOSDualVerifier(addresses.stateTransition.verifier).transferOwnership(addresses.governance);
        }

        IOwnable(addresses.daAddresses.rollupDAManager).transferOwnership(addresses.governance);
        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal virtual {
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "bridgehub_proxy_addr",
            discoveredBridgehub.bridgehubProxy
        );
        // Note: AssetRouterAddresses doesn't have legacyBridge, so we get it directly
        L1AssetRouter assetRouter = L1AssetRouter(discoveredBridgehub.assetRouter);
        vm.serializeAddress("bridges", "erc20_bridge_proxy_addr", address(assetRouter.legacyBridge()));
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", discoveredBridgehub.assetRouterAddresses.l1Nullifier);
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            discoveredBridgehub.assetRouter
        );
        // TODO(EVM-744): this has to be renamed to chain type manager
        vm.serializeAddress(
            "state_transition",
            "state_transition_proxy_addr",
            addresses.stateTransition.chainTypeManagerProxy
        );
        vm.serializeAddress("state_transition", "verifier_addr", addresses.stateTransition.verifier);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", addresses.stateTransition.genesisUpgrade);
        vm.serializeAddress("state_transition", "default_upgrade_addr", addresses.stateTransition.defaultUpgrade);
        vm.serializeAddress("state_transition", "eip7702_checker_addr", addresses.eip7702Checker);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "bytecodes_supplier_addr",
            addresses.stateTransition.bytecodesSupplier
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

        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeString("deployed_addresses", "bridges", bridges);
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);

        vm.serializeAddress(
            "deployed_addresses",
            "validator_timelock_addr",
            addresses.stateTransition.validatorTimelock
        );
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);
        vm.serializeAddress(
            "deployed_addresses",
            "no_da_validium_l1_validator_addr",
            addresses.daAddresses.noDAValidiumL1DAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "blobs_zksync_os_l1_da_validator_addr",
            addresses.daAddresses.l1BlobsDAValidatorZKsyncOS
        );
        vm.serializeAddress(
            "deployed_addresses",
            "rollup_l1_da_validator_addr",
            addresses.daAddresses.l1RollupDAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "avail_l1_da_validator_addr",
            addresses.daAddresses.availL1DAValidator
        );
        string memory deployedAddresses = vm.serializeString("deployed_addresses", "state_transition", stateTransition);

        vm.serializeUint(
            "chain_creation_params",
            "latest_protocol_version",
            config.contracts.chainCreationParams.latestProtocolVersion
        );
        vm.serializeBytes32(
            "chain_creation_params",
            "bootloader_hash",
            config.contracts.chainCreationParams.bootloaderHash
        );
        vm.serializeBytes32(
            "chain_creation_params",
            "default_aa_hash",
            config.contracts.chainCreationParams.defaultAAHash
        );
        vm.serializeBytes32(
            "chain_creation_params",
            "evm_emulator_hash",
            config.contracts.chainCreationParams.evmEmulatorHash
        );
        vm.serializeBytes32("chain_creation_params", "genesis_root", config.contracts.chainCreationParams.genesisRoot);
        vm.serializeUint(
            "chain_creation_params",
            "genesis_rollup_leaf_index",
            config.contracts.chainCreationParams.genesisRollupLeafIndex
        );
        string memory chainCreationParams = vm.serializeBytes32(
            "chain_creation_params",
            "genesis_batch_commitment",
            config.contracts.chainCreationParams.genesisBatchCommitment
        );

        vm.serializeAddress("contracts", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        string memory contracts = vm.serializeBytes32(
            "contracts",
            "create2_factory_salt",
            create2FactoryParams.factorySalt
        );

        vm.serializeString("root", "chain_creation_params", chainCreationParams);
        vm.serializeAddress("root", "multicall3_addr", config.contracts.multicall3Addr);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts", contracts);
        vm.serializeBool("root", "is_zk_sync_os", config.isZKsyncOS);
        string memory toml = vm.serializeString("root", "contracts_config", contractsConfig);
        vm.writeToml(toml, outputPath);
    }

    function prepareForceDeploymentsData() internal returns (bytes memory) {
        require(addresses.governance != address(0), "Governance address is not set");

        address dangerousTestOnlyForcedBeacon = _getDangerousTestOnlyForcedBeacon();

        FixedForceDeploymentsData memory data = _buildForceDeploymentsData(dangerousTestOnlyForcedBeacon);

        return abi.encode(data);
    }

    function _getDangerousTestOnlyForcedBeacon() private returns (address) {
        if (!config.supportL2LegacySharedBridgeTest) {
            return address(0);
        }

        L1AssetRouter assetRouter = L1AssetRouter(discoveredBridgehub.assetRouter);
        (address beacon, ) = L2LegacySharedBridgeTestHelper.calculateTestL2TokenBeaconAddress(
            address(assetRouter.legacyBridge()),
            discoveredBridgehub.assetRouterAddresses.l1Nullifier,
            addresses.governance
        );
        return beacon;
    }

    function _buildForceDeploymentsData(
        address dangerousTestOnlyForcedBeacon
    ) private returns (FixedForceDeploymentsData memory data) {
        data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            gatewayChainId: config.gatewayChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: discoveredBridgehub.assetRouter,
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
            interopCenterBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("InteropCenter.sol", "InteropCenter")
                : abi.encode(getL2BytecodeHash("InteropCenter")),
            interopHandlerBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("InteropHandler.sol", "InteropHandler")
                : abi.encode(getL2BytecodeHash("InteropHandler")),
            assetTrackerBytecodeInfo: config.isZKsyncOS
                ? Utils.getZKOSProxyUpgradeBytecodeInfo("L2AssetTracker.sol", "L2AssetTracker")
                : abi.encode(getL2BytecodeHash("L2AssetTracker")),
            // For newly created chains it it is expected that the following bridges are not present at the moment
            // of creation of the chain
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            aliasedChainRegistrationSender: AddressAliasHelper.applyL1ToL2Alias(
                discoveredBridgehub.chainRegistrationSenderProxy
            ),
            dangerousTestOnlyForcedBeacon: dangerousTestOnlyForcedBeacon
        });
    }

    function deployServerNotifier() internal returns (address implementation, address proxy) {
        // We will not store the address of the ProxyAdmin as it is trivial to query if needed.
        address ecosystemProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.chainAdmin, false);

        (implementation, proxy) = deployTuppWithContractAndProxyAdmin("ServerNotifier", ecosystemProxyAdmin, false);
    }

    function saveDiamondSelectors() public {
        AdminFacet adminFacet = new AdminFacet(1, RollupDAManager(address(0)), false);
        GettersFacet gettersFacet = new GettersFacet();
        MailboxFacet mailboxFacet = new MailboxFacet(
            1,
            1,
            discoveredBridgehub.chainAssetHandler,
            IEIP7702Checker(address(0)),
            false
        );
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

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
