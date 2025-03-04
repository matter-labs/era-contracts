// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "../Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {GatewayUpgrade} from "contracts/upgrades/GatewayUpgrade.sol";
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
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "./SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "./BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {Create2AndTransfer} from "../Create2AndTransfer.sol";

interface IBridgehubLegacy {
    function stateTransitionManager(uint256 chainId) external returns (address);
}

interface StateTransitionManagerLegacy {
    // Unlike the creation params for the new `ChainTypeManager`, it does not contain force deployments
    // fata.
    struct ChainCreationParams {
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        uint64 genesisIndexRepeatedStorageChanges;
        bytes32 genesisBatchCommitment;
        Diamond.DiamondCutData diamondCut;
    }
    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams) external;
}

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
    // The forced beacon address. It is needed only for internal testing.
    // MUST be equal to 0 in production.
    // It will be the job of the governance to ensure that this value is set correctly.
    address dangerousTestOnlyForcedBeacon;
}

// A subset of the ones used for tests
struct StateTransitionDeployedAddresses {
    address chainTypeManagerImplementation;
    address verifier;
    address adminFacet;
    address mailboxFacet;
    address executorFacet;
    address gettersFacet;
    address diamondInit;
    address genesisUpgrade;
    address defaultUpgrade;
    address validatorTimelock;
}

contract EcosystemUpgrade_v26_1 is Script {
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
        ExpectedL2Addresses expectedL2Addresses;
        address chainAdmin;
        address accessControlRestrictionAddress;
        address validatorTimelock;
        address gatewayUpgrade;
        address create2Factory;
        address transitionaryOwner;
        address upgradeTimer;
        address bytecodesSupplier;
        address l2WrappedBaseTokenStore;
        address blobVersionedHashRetriever;
    }

    struct ExpectedL2Addresses {
        address expectedRollupL2DAValidator;
        address expectedValidiumL2DAValidator;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
    }

    // solhint-disable-next-line gas-struct-packing
    struct L1NativeTokenVaultAddresses {
        address l1NativeTokenVaultImplementation;
        address l1NativeTokenVaultProxy;
    }

    struct DataAvailabilityDeployedAddresses {
        address rollupDAManager;
        address l1RollupDAValidator;
        address l1ValidiumDAValidator;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address ctmDeploymentTrackerImplementation;
        address ctmDeploymentTrackerProxy;
        address messageRootImplementation;
        address messageRootProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address sharedBridgeProxy;
        address sharedBridgeImplementation;
        address l1NullifierImplementation;
        address bridgedStandardERC20Implementation;
        address bridgedTokenBeacon;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 l1ChainId;
        address deployerAddress;
        uint256 eraChainId;
        address protocolUpgradeHandlerProxyAddress;
        // This is the address of the ecosystem admin.
        // Note, that it is not the owner, but rather the address that is responsible
        // for facilitating partially trusted, but not critical tasks.
        address ecosystemAdminAddress;
        bool testnetVerifier;
        uint256 governanceUpgradeTimerInitialDelay;
        bytes v26ChainCreationParams;
        ContractsConfig contracts;
        TokensConfig tokens;
    }

    // solhint-disable-next-line gas-struct-packing
    struct GeneratedData {
        bytes forceDeploymentsData;
        bytes diamondCutData;
    }

    // solhint-disable-next-line gas-struct-packing
    struct ContractsConfig {
        bytes32 create2FactorySalt;
        address create2FactoryAddr;
        uint256 validatorTimelockExecutionDelay;
        bytes32 genesisRoot;
        uint256 genesisRollupLeafIndex;
        bytes32 genesisBatchCommitment;
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
        uint256 maxNumberOfChains;
        bytes32 bootloaderHash;
        bytes32 defaultAAHash;
        address oldValidatorTimelock;
        address legacyErc20BridgeAddress;
        address bridgehubProxyAddress;
        address oldSharedBridgeProxyAddress;
        address stateTransitionManagerAddress;
        address transparentProxyAdmin;
        address eraDiamondProxy;
        uint256 newProtocolVersion;
        uint256 oldProtocolVersion;
        address l1LegacySharedBridge;
    }

    struct TokensConfig {
        address tokenWethAddress;
    }

    Config internal config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    uint256[] factoryDepsHashes;

    struct CachedBytecodeHashes {
        bytes32 sharedL2LegacyBridgeBytecodeHash;
        bytes32 erc20StandardImplBytecodeHash;
        bytes32 rollupL2DAValidatorBytecodeHash;
        bytes32 validiumL2DAValidatorBytecodeHash;
        bytes32 transparentUpgradableProxyBytecodeHash;
    }

    CachedBytecodeHashes internal cachedBytecodeHashes;

    // Just reads the input data for the script.
    function testInitialize(string memory configPath, string memory outputPath) public {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);
        outputPath = string.concat(root, outputPath);
        initializeConfig(configPath);
    }

    function prepareEcosystemContracts(string memory configPath, string memory outputPath) public {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(configPath);
        instantiateCreate2Factory();

        deployGenesisUpgrade();

        saveOutput(outputPath);
    }

    function run() public {
        prepareEcosystemContracts(
            vm.envString("GATEWAY_UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("GATEWAY_UPGRADE_ECOSYSTEM_OUTPUT")
        );
    }

    function getProtocolUpgradeHandlerAddress() public view returns (address) {
        return config.protocolUpgradeHandlerProxyAddress;
    }

    function getTransparentProxyAdmin() public view returns (address) {
        return config.contracts.transparentProxyAdmin;
    }

    function getNewProtocolVersion() public pure returns (uint256) {
        return 0x1a00000001;
    }

    function getProtocolUpgradeNonce() public pure returns (uint256) {
        return (getNewProtocolVersion() >> 32);
    }

    function getOldProtocolDeadline() public pure returns (uint256) {
        // It is by design
        return type(uint256).max;
    }

    function getOldProtocolVersion() public pure returns (uint256) {
        return 0x1a00000000;
    }

    function getUpgradeCalls() public returns (Call[] memory calls) {
        // Note, that we will also need to turn off the ability to create new chains
        // in the interim of the upgrade.
        Call memory setCreationParamsCall = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(ChainTypeManager.setChainCreationParams, (prepareNewChainCreationParams())),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = setCreationParamsCall;
    }

    function getEcosystemAdmin() external view returns (address) {
        return config.ecosystemAdminAddress;
    }

    function getBridgehub() external view returns (address) {
        return config.contracts.bridgehubProxyAddress;
    }

    function getChainTypeManager() external view returns (address) {
        return config.contracts.stateTransitionManagerAddress;
    }

    function getL1LegacySharedBridge() external view returns (address) {
        return config.contracts.l1LegacySharedBridge;
    }

    function getDiamondCutData() external view returns (bytes memory) {
        return generatedData.diamondCutData;
    }

    function initializeConfig(string memory configPath) internal {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");
        config.v26ChainCreationParams = toml.readBytes("$.v26_chain_creation_params");

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

        config.contracts.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");

        config.protocolUpgradeHandlerProxyAddress = toml.readAddress(
            "$.contracts.protocol_upgrade_handler_proxy_address"
        );

        address ctmAddress;

        try IBridgehubLegacy(config.contracts.bridgehubProxyAddress).stateTransitionManager(config.eraChainId) returns (
            address addr
        ) {
            ctmAddress = addr;
        } catch {
            ctmAddress = Bridgehub(config.contracts.bridgehubProxyAddress).chainTypeManager(config.eraChainId);
        }
        config.contracts.stateTransitionManagerAddress = ctmAddress;
        config.contracts.eraDiamondProxy = ChainTypeManager(config.contracts.stateTransitionManagerAddress)
            .getHyperchain(config.eraChainId);

        config.contracts.transparentProxyAdmin = toml.readAddress("$.contracts.transparent_proxy_admin");

        config.ecosystemAdminAddress = Bridgehub(config.contracts.bridgehubProxyAddress).admin();
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

    function deployGenesisUpgrade() internal {
        bytes memory bytecode = abi.encodePacked(type(L1GenesisUpgrade).creationCode);
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(contractAddress, "L1GenesisUpgrade", hex"");
        addresses.stateTransition.genesisUpgrade = contractAddress;
    }

    function prepareForceDeploymentsData() public view returns (bytes memory) {
        ChainCreationParams memory v26ChainCreationParams = abi.decode(
            config.v26ChainCreationParams,
            (ChainCreationParams)
        );

        return v26ChainCreationParams.forceDeploymentsData;
    }

    function prepareNewChainCreationParams() internal returns (ChainCreationParams memory chainCreationParams) {
        ChainCreationParams memory v26ChainCreationParams = abi.decode(
            config.v26ChainCreationParams,
            (ChainCreationParams)
        );

        // Diamond cut does not change.
        generatedData.diamondCutData = abi.encode(v26ChainCreationParams.diamondCut);
        generatedData.forceDeploymentsData = v26ChainCreationParams.forceDeploymentsData;

        chainCreationParams = ChainCreationParams({
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            // DiamondCut and forceDeploymentsData dont change.
            diamondCut: v26ChainCreationParams.diamondCut,
            forceDeploymentsData: v26ChainCreationParams.forceDeploymentsData
        });
    }

    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams
    ) internal {
        notifyAboutDeployment(contractAddr, contractName, constructorParams, contractName);
    }

    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        string memory displayName
    ) internal {
        string memory basicMessage = string.concat(displayName, " has been deployed at ", vm.toString(contractAddr));
        console.log(basicMessage);

        string memory forgeMessage;
        if (constructorParams.length == 0) {
            forgeMessage = string.concat("forge verify-contract ", vm.toString(contractAddr), " ", contractName);
        } else {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                contractName,
                " --constructor-args ",
                vm.toString(constructorParams)
            );
        }

        console.log(forgeMessage);
    }

    function saveOutput(string memory outputPath) internal {
        prepareNewChainCreationParams();

        vm.serializeAddress("state_transition", "admin_facet_addr", addresses.stateTransition.adminFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", addresses.stateTransition.mailboxFacet);
        vm.serializeAddress("state_transition", "executor_facet_addr", addresses.stateTransition.executorFacet);
        vm.serializeAddress("state_transition", "getters_facet_addr", addresses.stateTransition.gettersFacet);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", addresses.stateTransition.genesisUpgrade);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            addresses.stateTransition.defaultUpgrade
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

        vm.serializeBytes("contracts_config", "diamond_cut_data", generatedData.diamondCutData);

        vm.serializeBytes("contracts_config", "force_deployments_data", generatedData.forceDeploymentsData);

        vm.serializeUint("contracts_config", "new_protocol_version", config.contracts.newProtocolVersion);

        string memory contractsConfig = vm.serializeUint(
            "contracts_config",
            "old_protocol_version",
            config.contracts.oldProtocolVersion
        );

        string memory deployedAddresses = vm.serializeString("deployed_addresses", "state_transition", stateTransition);

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", config.contracts.create2FactorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);

        vm.serializeBytes("root", "governance_upgrade_calls", abi.encode(getUpgradeCalls()));

        string memory toml = vm.serializeAddress(
            "root",
            "protocol_upgrade_handler_proxy_address",
            config.protocolUpgradeHandlerProxyAddress
        );

        vm.writeToml(toml, outputPath);
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.contracts.create2FactorySalt, addresses.create2Factory);
    }

    function mergeCalls(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory result) {
        result = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
