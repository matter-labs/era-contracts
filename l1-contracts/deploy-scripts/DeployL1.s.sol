// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
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
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "./ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";

struct FixedForceDeploymentsData {
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedL1Governance;
    uint256 maxNumberOfZKChains;
    bytes32 bridgehubBytecodeHash;
    bytes32 l2AssetRouterBytecodeHash;
    bytes32 l2NtvBytecodeHash;
    bytes32 messageRootBytecodeHash;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
    address l2BridgeProxyOwnerAddress;
    address l2BridgedStandardERC20ProxyOwnerAddress;
}

contract DeployL1Script is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // solhint-disable-next-line gas-struct-packing
    struct DeployedAddresses {
        BridgehubDeployedAddresses bridgehub;
        StateTransitionDeployedAddresses stateTransition;
        BridgesDeployedAddresses bridges;
        L1NativeTokenVaultAddresses vaults;
        DataAvailabilityDeployedAddresses daAddresses;
        address transparentProxyAdmin;
        address governance;
        address chainAdmin;
        address accessControlRestrictionAddress;
        address blobVersionedHashRetriever;
        address validatorTimelock;
        address create2Factory;
    }

    // solhint-disable-next-line gas-struct-packing
    struct L1NativeTokenVaultAddresses {
        address l1NativeTokenVaultImplementation;
        address l1NativeTokenVaultProxy;
    }

    struct DataAvailabilityDeployedAddresses {
        address l1RollupDAValidator;
        address l1ValidiumDAValidator;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address bridgehubProxy;
        address ctmDeploymentTrackerImplementation;
        address ctmDeploymentTrackerProxy;
        address messageRootImplementation;
        address messageRootProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address erc20BridgeProxy;
        address sharedBridgeImplementation;
        address sharedBridgeProxy;
        address l1NullifierImplementation;
        address l1NullifierProxy;
        address bridgedStandardERC20Implementation;
        address bridgedTokenBeacon;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 l1ChainId;
        address deployerAddress;
        uint256 eraChainId;
        address ownerAddress;
        bool testnetVerifier;
        ContractsConfig contracts;
        TokensConfig tokens;
    }

    // solhint-disable-next-line gas-struct-packing
    struct GeneratedData {
        bytes forceDeploymentsData;
    }

    // solhint-disable-next-line gas-struct-packing
    struct ContractsConfig {
        bytes32 create2FactorySalt;
        address create2FactoryAddr;
        address multicall3Addr;
        uint256 validatorTimelockExecutionDelay;
        bytes32 genesisRoot;
        uint256 genesisRollupLeafIndex;
        bytes32 genesisBatchCommitment;
        uint256 latestProtocolVersion;
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
        uint256 priorityTxMaxGasLimit;
        PubdataPricingMode diamondInitPubdataPricingMode;
        uint256 diamondInitBatchOverheadL1Gas;
        uint256 diamondInitMaxPubdataPerBatch;
        uint256 diamondInitMaxL2GasPerBatch;
        uint256 diamondInitPriorityTxMaxPubdata;
        uint256 diamondInitMinimalL2GasPrice;
        address governanceSecurityCouncilAddress;
        uint256 governanceMinDelay;
        uint256 maxNumberOfChains;
        bytes diamondCutData;
        bytes32 bootloaderHash;
        bytes32 defaultAAHash;
    }

    struct TokensConfig {
        address tokenWethAddress;
    }

    Config internal config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    function run() public {
        console.log("Deploying L1 contracts");

        runInner("/script-config/config-deploy-l1.toml", "/script-out/output-deploy-l1.toml");
    }

    function runForTest() public {
        runInner(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"));
    }

    function runInner(string memory inputPath, string memory outputPath) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(inputPath);

        instantiateCreate2Factory();
        deployIfNeededMulticall3();

        deployVerifier();

        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployDAValidators();
        deployValidatorTimelock();

        deployGovernance();
        deployChainAdmin();
        deployTransparentProxyAdmin();
        deployBridgehubContract();
        deployMessageRootContract();

        deployL1NullifierContracts();
        deploySharedBridgeContracts();
        deployBridgedStandardERC20Implementation();
        deployBridgedTokenBeacon();
        deployL1NativeTokenVaultImplementation();
        deployL1NativeTokenVaultProxy();
        deployErc20BridgeImplementation();
        deployErc20BridgeProxy();
        updateSharedBridge();
        deployCTMDeploymentTracker();
        setBridgehubParams();

        initializeGeneratedData();

        deployBlobVersionedHashRetriever();
        deployChainTypeManagerContract();
        setChainTypeManagerInValidatorTimelock();

        updateOwners();

        saveOutput(outputPath);
    }

    function getBridgehubProxyAddress() public view returns (address) {
        return addresses.bridgehub.bridgehubProxy;
    }

    function getSharedBridgeProxyAddress() public view returns (address) {
        return addresses.bridges.sharedBridgeProxy;
    }

    function getNativeTokenVaultProxyAddress() public view returns (address) {
        return addresses.vaults.l1NativeTokenVaultProxy;
    }

    function getL1NullifierProxyAddress() public view returns (address) {
        return addresses.bridges.l1NullifierProxy;
    }

    function getOwnerAddress() public view returns (address) {
        return config.ownerAddress;
    }

    function getCTM() public view returns (address) {
        return addresses.stateTransition.chainTypeManagerProxy;
    }

    function getInitialDiamondCutData() public view returns (bytes memory) {
        return config.contracts.diamondCutData;
    }

    function getCTMDeploymentTrackerAddress() public view returns (address) {
        return addresses.bridgehub.ctmDeploymentTrackerProxy;
    }

    function initializeConfig(string memory configPath) internal {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

        config.contracts.governanceSecurityCouncilAddress = toml.readAddress(
            "$.contracts.governance_security_council_address"
        );
        config.contracts.governanceMinDelay = toml.readUint("$.contracts.governance_min_delay");
        config.contracts.maxNumberOfChains = toml.readUint("$.contracts.max_number_of_chains");
        config.contracts.create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            config.contracts.create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        config.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.genesisRoot = toml.readBytes32("$.contracts.genesis_root");
        config.contracts.genesisRollupLeafIndex = toml.readUint("$.contracts.genesis_rollup_leaf_index");
        config.contracts.genesisBatchCommitment = toml.readBytes32("$.contracts.genesis_batch_commitment");
        config.contracts.latestProtocolVersion = toml.readUint("$.contracts.latest_protocol_version");
        config.contracts.recursionNodeLevelVkHash = toml.readBytes32("$.contracts.recursion_node_level_vk_hash");
        config.contracts.recursionLeafLevelVkHash = toml.readBytes32("$.contracts.recursion_leaf_level_vk_hash");
        config.contracts.recursionCircuitsSetVksHash = toml.readBytes32("$.contracts.recursion_circuits_set_vks_hash");
        config.contracts.priorityTxMaxGasLimit = toml.readUint("$.contracts.priority_tx_max_gas_limit");
        config.contracts.diamondInitPubdataPricingMode = PubdataPricingMode(
            toml.readUint("$.contracts.diamond_init_pubdata_pricing_mode")
        );
        config.contracts.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.contracts.diamond_init_batch_overhead_l1_gas"
        );
        config.contracts.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_pubdata_per_batch"
        );
        config.contracts.diamondInitMaxL2GasPerBatch = toml.readUint("$.contracts.diamond_init_max_l2_gas_per_batch");
        config.contracts.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.contracts.diamond_init_priority_tx_max_pubdata"
        );
        config.contracts.diamondInitMinimalL2GasPrice = toml.readUint("$.contracts.diamond_init_minimal_l2_gas_price");
        config.contracts.defaultAAHash = toml.readBytes32("$.contracts.default_aa_hash");
        config.contracts.bootloaderHash = toml.readBytes32("$.contracts.bootloader_hash");

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
    }

    function initializeGeneratedData() internal {
        generatedData.forceDeploymentsData = prepareForceDeploymentsData();
    }

    function instantiateCreate2Factory() internal {
        address contractAddress;

        bool isDeterministicDeployed = DETERMINISTIC_CREATE2_ADDRESS.code.length > 0;
        bool isConfigured = config.contracts.create2FactoryAddr != address(0);

        if (isConfigured) {
            if (config.contracts.create2FactoryAddr.code.length == 0) {
                revert AddressHasNoCode(config.contracts.create2FactoryAddr);
            }
            contractAddress = config.contracts.create2FactoryAddr;
            console.log("Using configured Create2Factory address:", contractAddress);
        } else if (isDeterministicDeployed) {
            contractAddress = DETERMINISTIC_CREATE2_ADDRESS;
            console.log("Using deterministic Create2Factory address:", contractAddress);
        } else {
            contractAddress = Utils.deployCreate2Factory();
            console.log("Create2Factory deployed at:", contractAddress);
        }

        addresses.create2Factory = contractAddress;
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on public networks
        if (MULTICALL3_ADDRESS.code.length == 0) {
            address contractAddress = deployViaCreate2(type(Multicall3).creationCode);
            console.log("Multicall3 deployed at:", contractAddress);
            config.contracts.multicall3Addr = contractAddress;
        } else {
            config.contracts.multicall3Addr = MULTICALL3_ADDRESS;
        }
    }

    function deployVerifier() internal {
        bytes memory code;
        if (config.testnetVerifier) {
            code = type(TestnetVerifier).creationCode;
        } else {
            code = type(Verifier).creationCode;
        }
        address contractAddress = deployViaCreate2(code);
        console.log("Verifier deployed at:", contractAddress);
        addresses.stateTransition.verifier = contractAddress;
    }

    function deployDefaultUpgrade() internal {
        address contractAddress = deployViaCreate2(type(DefaultUpgrade).creationCode);
        console.log("DefaultUpgrade deployed at:", contractAddress);
        addresses.stateTransition.defaultUpgrade = contractAddress;
    }

    function deployGenesisUpgrade() internal {
        bytes memory bytecode = abi.encodePacked(type(L1GenesisUpgrade).creationCode);
        address contractAddress = deployViaCreate2(bytecode);
        console.log("GenesisUpgrade deployed at:", contractAddress);
        addresses.stateTransition.genesisUpgrade = contractAddress;
    }

    function deployDAValidators() internal {
        address contractAddress = deployViaCreate2(Utils.readRollupDAValidatorBytecode());
        console.log("L1RollupDAValidator deployed at:", contractAddress);
        addresses.daAddresses.l1RollupDAValidator = contractAddress;

        contractAddress = deployViaCreate2(type(ValidiumL1DAValidator).creationCode);
        console.log("L1ValidiumDAValidator deployed at:", contractAddress);
        addresses.daAddresses.l1ValidiumDAValidator = contractAddress;
    }

    function deployValidatorTimelock() internal {
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        bytes memory bytecode = abi.encodePacked(
            type(ValidatorTimelock).creationCode,
            abi.encode(config.deployerAddress, executionDelay, config.eraChainId)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ValidatorTimelock deployed at:", contractAddress);
        addresses.validatorTimelock = contractAddress;
    }

    function deployGovernance() internal {
        bytes memory bytecode = abi.encodePacked(
            type(Governance).creationCode,
            abi.encode(
                config.ownerAddress,
                config.contracts.governanceSecurityCouncilAddress,
                config.contracts.governanceMinDelay
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Governance deployed at:", contractAddress);
        addresses.governance = contractAddress;
    }

    function deployChainAdmin() internal {
        bytes memory accessControlRestrictionBytecode = abi.encodePacked(
            type(AccessControlRestriction).creationCode,
            abi.encode(uint256(0), config.ownerAddress)
        );

        address accessControlRestriction = deployViaCreate2(accessControlRestrictionBytecode);
        console.log("Access control restriction deployed at:", accessControlRestriction);
        address[] memory restrictions = new address[](1);
        restrictions[0] = accessControlRestriction;
        addresses.accessControlRestrictionAddress = accessControlRestriction;

        bytes memory bytecode = abi.encodePacked(type(ChainAdmin).creationCode, abi.encode(restrictions));
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ChainAdmin deployed at:", contractAddress);
        addresses.chainAdmin = contractAddress;
    }

    function deployTransparentProxyAdmin() internal {
        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(addresses.governance);
        vm.stopBroadcast();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        addresses.transparentProxyAdmin = address(proxyAdmin);
    }

    function deployBridgehubContract() internal {
        bytes memory bridgeHubBytecode = abi.encodePacked(
            type(Bridgehub).creationCode,
            abi.encode(config.l1ChainId, config.ownerAddress, (config.contracts.maxNumberOfChains))
        );
        address bridgehubImplementation = deployViaCreate2(bridgeHubBytecode);
        console.log("Bridgehub Implementation deployed at:", bridgehubImplementation);
        addresses.bridgehub.bridgehubImplementation = bridgehubImplementation;

        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                bridgehubImplementation,
                addresses.transparentProxyAdmin,
                abi.encodeCall(Bridgehub.initialize, (config.deployerAddress))
            )
        );
        address bridgehubProxy = deployViaCreate2(bytecode);
        console.log("Bridgehub Proxy deployed at:", bridgehubProxy);
        addresses.bridgehub.bridgehubProxy = bridgehubProxy;
    }

    function deployMessageRootContract() internal {
        bytes memory messageRootBytecode = abi.encodePacked(
            type(MessageRoot).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy)
        );
        address messageRootImplementation = deployViaCreate2(messageRootBytecode);
        console.log("MessageRoot Implementation deployed at:", messageRootImplementation);
        addresses.bridgehub.messageRootImplementation = messageRootImplementation;

        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                messageRootImplementation,
                addresses.transparentProxyAdmin,
                abi.encodeCall(MessageRoot.initialize, ())
            )
        );
        address messageRootProxy = deployViaCreate2(bytecode);
        console.log("Message Root Proxy deployed at:", messageRootProxy);
        addresses.bridgehub.messageRootProxy = messageRootProxy;
    }

    function deployCTMDeploymentTracker() internal {
        bytes memory ctmDTBytecode = abi.encodePacked(
            type(CTMDeploymentTracker).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy, addresses.bridges.sharedBridgeProxy)
        );
        address ctmDTImplementation = deployViaCreate2(ctmDTBytecode);
        console.log("CTM Deployment Tracker Implementation deployed at:", ctmDTImplementation);
        addresses.bridgehub.ctmDeploymentTrackerImplementation = ctmDTImplementation;

        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                ctmDTImplementation,
                addresses.transparentProxyAdmin,
                abi.encodeCall(CTMDeploymentTracker.initialize, (config.deployerAddress))
            )
        );
        address ctmDTProxy = deployViaCreate2(bytecode);
        console.log("CTM Deployment Tracker Proxy deployed at:", ctmDTProxy);
        addresses.bridgehub.ctmDeploymentTrackerProxy = ctmDTProxy;
    }

    function deployBlobVersionedHashRetriever() internal {
        // solc contracts/state-transition/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
        bytes memory bytecode = hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
        address contractAddress = deployViaCreate2(bytecode);
        console.log("BlobVersionedHashRetriever deployed at:", contractAddress);
        addresses.blobVersionedHashRetriever = contractAddress;
    }

    function deployChainTypeManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployChainTypeManagerImplementation();
        deployChainTypeManagerProxy();
        registerChainTypeManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        address executorFacet = deployViaCreate2(type(ExecutorFacet).creationCode);
        console.log("ExecutorFacet deployed at:", executorFacet);
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(
            abi.encodePacked(type(AdminFacet).creationCode, abi.encode(config.l1ChainId))
        );
        console.log("AdminFacet deployed at:", adminFacet);
        addresses.stateTransition.adminFacet = adminFacet;

        address mailboxFacet = deployViaCreate2(
            abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(config.eraChainId, config.l1ChainId))
        );
        console.log("MailboxFacet deployed at:", mailboxFacet);
        addresses.stateTransition.mailboxFacet = mailboxFacet;

        address gettersFacet = deployViaCreate2(type(GettersFacet).creationCode);
        console.log("GettersFacet deployed at:", gettersFacet);
        addresses.stateTransition.gettersFacet = gettersFacet;

        address diamondInit = deployViaCreate2(type(DiamondInit).creationCode);
        console.log("DiamondInit deployed at:", diamondInit);
        addresses.stateTransition.diamondInit = diamondInit;
    }

    function deployChainTypeManagerImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(ChainTypeManager).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ChainTypeManagerImplementation deployed at:", contractAddress);
        addresses.stateTransition.chainTypeManagerImplementation = contractAddress;
    }

    function deployChainTypeManagerProxy() internal {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: addresses.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: addresses.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: addresses.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: addresses.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
        });

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
            batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
            maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
            maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
            priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
            minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(addresses.stateTransition.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: config.contracts.bootloaderHash,
            l2DefaultAccountBytecodeHash: config.contracts.defaultAAHash,
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            feeParams: feeParams,
            blobVersionedHashRetriever: addresses.blobVersionedHashRetriever
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        config.contracts.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: generatedData.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: msg.sender,
            validatorTimelock: addresses.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: config.contracts.latestProtocolVersion
        });

        address contractAddress = deployViaCreate2(
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    addresses.stateTransition.chainTypeManagerImplementation,
                    addresses.transparentProxyAdmin,
                    abi.encodeCall(ChainTypeManager.initialize, (diamondInitData))
                )
            )
        );
        console.log("ChainTypeManagerProxy deployed at:", contractAddress);
        addresses.stateTransition.chainTypeManagerProxy = contractAddress;
    }

    function registerChainTypeManager() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        console.log("ChainTypeManager registered");
        CTMDeploymentTracker ctmDT = CTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy);
        // vm.startBroadcast(msg.sender);
        L1AssetRouter sharedBridge = L1AssetRouter(addresses.bridges.sharedBridgeProxy);
        sharedBridge.setAssetDeploymentTracker(
            bytes32(uint256(uint160(addresses.stateTransition.chainTypeManagerProxy))),
            address(ctmDT)
        );
        console.log("CTM DT whitelisted");

        ctmDT.registerCTMAssetOnL1(addresses.stateTransition.chainTypeManagerProxy);
        vm.stopBroadcast();
        console.log("CTM registered in CTMDeploymentTracker");

        bytes32 assetId = bridgehub.ctmAssetId(addresses.stateTransition.chainTypeManagerProxy);
        // console.log(address(bridgehub.ctmDeployer()), addresses.bridgehub.ctmDeploymentTrackerProxy);
        // console.log(address(bridgehub.ctmDeployer().BRIDGE_HUB()), addresses.bridgehub.bridgehubProxy);
        console.log(
            "CTM in router 1",
            sharedBridge.assetHandlerAddress(assetId),
            bridgehub.ctmAssetIdToAddress(assetId)
        );
    }

    function setChainTypeManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        vm.broadcast(msg.sender);
        validatorTimelock.setChainTypeManager(IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy));
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
        bytes memory bytecode = abi.encodePacked(
            type(DiamondProxy).creationCode,
            abi.encode(config.l1ChainId, diamondCut)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("DiamondProxy deployed at:", contractAddress);
        addresses.stateTransition.diamondProxy = contractAddress;
    }

    function deploySharedBridgeContracts() internal {
        deploySharedBridgeImplementation();
        deploySharedBridgeProxy();
    }

    function deployL1NullifierContracts() internal {
        deployL1NullifierImplementation();
        deployL1NullifierProxy();
    }

    function deployL1NullifierImplementation() internal {
        // TODO(EVM-743): allow non-dev nullifier in the local deployment
        bytes memory bytecode = abi.encodePacked(
            type(L1NullifierDev).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(addresses.bridgehub.bridgehubProxy, config.eraChainId, addresses.stateTransition.diamondProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NullifierImplementation deployed at:", contractAddress);
        addresses.bridges.l1NullifierImplementation = contractAddress;
    }

    function deployL1NullifierProxy() internal {
        bytes memory initCalldata = abi.encodeCall(L1Nullifier.initialize, (config.deployerAddress, 1, 1, 1, 0));
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridges.l1NullifierImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NullifierProxy deployed at:", contractAddress);
        addresses.bridges.l1NullifierProxy = contractAddress;
    }

    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1AssetRouter).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                addresses.bridgehub.bridgehubProxy,
                addresses.bridges.l1NullifierProxy,
                config.eraChainId,
                addresses.stateTransition.diamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeImplementation deployed at:", contractAddress);
        addresses.bridges.sharedBridgeImplementation = contractAddress;
    }

    function deploySharedBridgeProxy() internal {
        bytes memory initCalldata = abi.encodeCall(L1AssetRouter.initialize, (config.deployerAddress));
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridges.sharedBridgeImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeProxy deployed at:", contractAddress);
        addresses.bridges.sharedBridgeProxy = contractAddress;
    }

    function setBridgehubParams() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addTokenAssetId(bridgehub.baseTokenAssetId(config.eraChainId));
        // bridgehub.setSharedBridge(addresses.bridges.sharedBridgeProxy);
        bridgehub.setAddresses(
            addresses.bridges.sharedBridgeProxy,
            ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy),
            IMessageRoot(addresses.bridgehub.messageRootProxy)
        );
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function deployErc20BridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1ERC20Bridge).creationCode,
            abi.encode(
                addresses.bridges.l1NullifierProxy,
                addresses.bridges.sharedBridgeProxy,
                addresses.vaults.l1NativeTokenVaultProxy,
                config.eraChainId
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Erc20BridgeImplementation deployed at:", contractAddress);
        addresses.bridges.erc20BridgeImplementation = contractAddress;
    }

    function deployErc20BridgeProxy() internal {
        bytes memory initCalldata = abi.encodeCall(L1ERC20Bridge.initialize, ());
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridges.erc20BridgeImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Erc20BridgeProxy deployed at:", contractAddress);
        addresses.bridges.erc20BridgeProxy = contractAddress;
    }

    function updateSharedBridge() internal {
        L1AssetRouter sharedBridge = L1AssetRouter(addresses.bridges.sharedBridgeProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(L1ERC20Bridge(addresses.bridges.erc20BridgeProxy));
        console.log("SharedBridge updated with ERC20Bridge address");
    }

    function deployBridgedStandardERC20Implementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(BridgedStandardERC20).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode()
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("BridgedStandardERC20Implementation deployed at:", contractAddress);
        addresses.bridges.bridgedStandardERC20Implementation = contractAddress;
    }

    function deployBridgedTokenBeacon() internal {
        bytes memory bytecode = abi.encodePacked(
            type(UpgradeableBeacon).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(addresses.bridges.bridgedStandardERC20Implementation)
        );
        UpgradeableBeacon beacon = new UpgradeableBeacon(addresses.bridges.bridgedStandardERC20Implementation);
        address contractAddress = address(beacon);
        beacon.transferOwnership(config.ownerAddress);
        console.log("BridgedTokenBeacon deployed at:", contractAddress);
        addresses.bridges.bridgedTokenBeacon = contractAddress;
    }

    function deployL1NativeTokenVaultImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1NativeTokenVault).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                addresses.bridges.sharedBridgeProxy,
                config.eraChainId,
                addresses.bridges.l1NullifierProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NativeTokenVaultImplementation deployed at:", contractAddress);
        addresses.vaults.l1NativeTokenVaultImplementation = contractAddress;
    }

    function deployL1NativeTokenVaultProxy() internal {
        bytes memory initCalldata = abi.encodeCall(
            L1NativeTokenVault.initialize,
            (config.ownerAddress, addresses.bridges.bridgedTokenBeacon)
        );
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.vaults.l1NativeTokenVaultImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NativeTokenVaultProxy deployed at:", contractAddress);
        addresses.vaults.l1NativeTokenVaultProxy = contractAddress;

        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.sharedBridgeProxy);
        IL1Nullifier l1Nullifier = IL1Nullifier(addresses.bridges.l1NullifierProxy);
        // Ownable ownable = Ownable(addresses.bridges.sharedBridgeProxy);

        vm.broadcast(msg.sender);
        sharedBridge.setNativeTokenVault(INativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1AssetRouter(addresses.bridges.sharedBridgeProxy);

        vm.broadcast(msg.sender);
        IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerEthToken();

        // bytes memory data = abi.encodeCall(sharedBridge.setNativeTokenVault, (IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy)));
        // Utils.executeUpgrade({
        //     _governor: ownable.owner(),
        //     _salt: bytes32(0),
        //     _target: addresses.bridges.sharedBridgeProxy,
        //     _data: data,
        //     _value: 0,
        //     _delay: 0
        // });
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        bridgehub.transferOwnership(addresses.governance);
        bridgehub.setPendingAdmin(addresses.chainAdmin);

        L1AssetRouter sharedBridge = L1AssetRouter(addresses.bridges.sharedBridgeProxy);
        sharedBridge.transferOwnership(addresses.governance);

        ChainTypeManager ctm = ChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        ctm.transferOwnership(addresses.governance);
        ctm.setPendingAdmin(addresses.chainAdmin);

        CTMDeploymentTracker ctmDeploymentTracker = CTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy);
        ctmDeploymentTracker.transferOwnership(addresses.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal {
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
            addresses.bridges.sharedBridgeImplementation
        );
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            addresses.bridges.sharedBridgeProxy
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
        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);

        vm.serializeAddress("deployed_addresses", "validator_timelock_addr", addresses.validatorTimelock);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);
        vm.serializeString("deployed_addresses", "state_transition", stateTransition);

        vm.serializeAddress(
            "deployed_addresses",
            "rollup_l1_da_validator_addr",
            addresses.daAddresses.l1RollupDAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "validium_l1_da_validator_addr",
            addresses.daAddresses.l1ValidiumDAValidator
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
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.contracts.create2FactorySalt, addresses.create2Factory);
    }

    function prepareForceDeploymentsData() internal view returns (bytes memory) {
        require(addresses.governance != address(0), "Governance address is not set");

        FixedForceDeploymentsData memory data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: addresses.bridges.sharedBridgeProxy,
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
            // For newly created chains it it is expected that the following bridges are not present
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            l2BridgeProxyOwnerAddress: address(0),
            l2BridgedStandardERC20ProxyOwnerAddress: address(0)
        });

        return abi.encode(data);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
