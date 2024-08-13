// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";

contract DeployL1Script is Script {
    using stdToml for string;

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    address constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct DeployedAddresses {
        BridgehubDeployedAddresses bridgehub;
        StateTransitionDeployedAddresses stateTransition;
        BridgesDeployedAddresses bridges;
        address transparentProxyAdmin;
        address governance;
        address chainAdmin;
        address blobVersionedHashRetriever;
        address validatorTimelock;
        address create2Factory;
    }

    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address bridgehubProxy;
    }

    struct StateTransitionDeployedAddresses {
        address stateTransitionProxy;
        address stateTransitionImplementation;
        address verifier;
        address adminFacet;
        address mailboxFacet;
        address executorFacet;
        address gettersFacet;
        address diamondInit;
        address genesisUpgrade;
        address defaultUpgrade;
        address diamondProxy;
    }

    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address erc20BridgeProxy;
        address sharedBridgeImplementation;
        address sharedBridgeProxy;
    }

    struct Config {
        uint256 l1ChainId;
        uint256 eraChainId;
        address deployerAddress;
        address ownerAddress;
        bool testnetVerifier;
        ContractsConfig contracts;
        TokensConfig tokens;
    }

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

    Config config;
    DeployedAddresses addresses;

    function run() public {
        console.log("Deploying L1 contracts");

        initializeConfig();

        instantiateCreate2Factory();
        deployIfNeededMulticall3();

        deployVerifier();

        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployValidatorTimelock();

        deployGovernance();
        deployChainAdmin();
        deployTransparentProxyAdmin();
        deployBridgehubContract();
        deployBlobVersionedHashRetriever();
        deployStateTransitionManagerContract();
        setStateTransitionManagerInValidatorTimelock();

        deployDiamondProxy();

        deploySharedBridgeContracts();
        deployErc20BridgeImplementation();
        deployErc20BridgeProxy();
        updateSharedBridge();

        updateOwners();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l1.toml");
        string memory toml = vm.readFile(path);

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

    function instantiateCreate2Factory() internal {
        address contractAddress;

        bool isDeterministicDeployed = DETERMINISTIC_CREATE2_ADDRESS.code.length > 0;
        bool isConfigured = config.contracts.create2FactoryAddr != address(0);

        if (isConfigured) {
            if (config.contracts.create2FactoryAddr.code.length == 0) {
                revert("Create2Factory configured address is empty");
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
        address contractAddress = deployViaCreate2(type(GenesisUpgrade).creationCode);
        console.log("GenesisUpgrade deployed at:", contractAddress);
        addresses.stateTransition.genesisUpgrade = contractAddress;
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
        bytes memory bytecode = abi.encodePacked(
            type(ChainAdmin).creationCode,
            abi.encode(config.ownerAddress, address(0))
        );
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
        address bridgehubImplementation = deployViaCreate2(type(Bridgehub).creationCode);
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

    function deployBlobVersionedHashRetriever() internal {
        // solc contracts/state-transition/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
        bytes memory bytecode = hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
        address contractAddress = deployViaCreate2(bytecode);
        console.log("BlobVersionedHashRetriever deployed at:", contractAddress);
        addresses.blobVersionedHashRetriever = contractAddress;
    }

    function deployStateTransitionManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployStateTransitionManagerImplementation();
        deployStateTransitionManagerProxy();
        registerStateTransitionManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        address executorFacet = deployViaCreate2(type(ExecutorFacet).creationCode);
        console.log("ExecutorFacet deployed at:", executorFacet);
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(type(AdminFacet).creationCode);
        console.log("AdminFacet deployed at:", adminFacet);
        addresses.stateTransition.adminFacet = adminFacet;

        address mailboxFacet = deployViaCreate2(
            abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(config.eraChainId))
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

    function deployStateTransitionManagerImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(StateTransitionManager).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy),
            abi.encode(config.contracts.maxNumberOfChains)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("StateTransitionManagerImplementation deployed at:", contractAddress);
        addresses.stateTransition.stateTransitionImplementation = contractAddress;
    }

    function deployStateTransitionManagerProxy() internal {
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
            diamondCut: diamondCut
        });

        StateTransitionManagerInitializeData memory diamondInitData = StateTransitionManagerInitializeData({
            owner: msg.sender,
            validatorTimelock: addresses.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: config.contracts.latestProtocolVersion
        });

        address contractAddress = deployViaCreate2(
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    addresses.stateTransition.stateTransitionImplementation,
                    addresses.transparentProxyAdmin,
                    abi.encodeCall(StateTransitionManager.initialize, (diamondInitData))
                )
            )
        );
        console.log("StateTransitionManagerProxy deployed at:", contractAddress);
        addresses.stateTransition.stateTransitionProxy = contractAddress;
    }

    function registerStateTransitionManager() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.broadcast();
        bridgehub.addStateTransitionManager(addresses.stateTransition.stateTransitionProxy);
        console.log("StateTransitionManager registered");
    }

    function setStateTransitionManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        vm.broadcast();
        validatorTimelock.setStateTransitionManager(
            IStateTransitionManager(addresses.stateTransition.stateTransitionProxy)
        );
        console.log("StateTransitionManager set in ValidatorTimelock");
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
        registerSharedBridge();
    }

    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1SharedBridge).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                addresses.bridgehub.bridgehubProxy,
                config.eraChainId,
                addresses.stateTransition.diamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeImplementation deployed at:", contractAddress);
        addresses.bridges.sharedBridgeImplementation = contractAddress;
    }

    function deploySharedBridgeProxy() internal {
        bytes memory initCalldata = abi.encodeCall(L1SharedBridge.initialize, (config.deployerAddress));
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridges.sharedBridgeImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeProxy deployed at:", contractAddress);
        addresses.bridges.sharedBridgeProxy = contractAddress;
    }

    function registerSharedBridge() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast();
        bridgehub.addToken(ADDRESS_ONE);
        bridgehub.setSharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function deployErc20BridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1ERC20Bridge).creationCode,
            abi.encode(addresses.bridges.sharedBridgeProxy)
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
        L1SharedBridge sharedBridge = L1SharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.broadcast();
        sharedBridge.setL1Erc20Bridge(addresses.bridges.erc20BridgeProxy);
        console.log("SharedBridge updated with ERC20Bridge address");
    }

    function updateOwners() internal {
        vm.startBroadcast();

        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        bridgehub.transferOwnership(addresses.governance);

        L1SharedBridge sharedBridge = L1SharedBridge(addresses.bridges.sharedBridgeProxy);
        sharedBridge.transferOwnership(addresses.governance);

        StateTransitionManager stm = StateTransitionManager(addresses.stateTransition.stateTransitionProxy);
        stm.transferOwnership(addresses.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput() internal {
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", addresses.bridgehub.bridgehubProxy);
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "bridgehub_implementation_addr",
            addresses.bridgehub.bridgehubImplementation
        );

        vm.serializeAddress(
            "state_transition",
            "state_transition_proxy_addr",
            addresses.stateTransition.stateTransitionProxy
        );
        vm.serializeAddress(
            "state_transition",
            "state_transition_implementation_addr",
            addresses.stateTransition.stateTransitionImplementation
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
            "diamond_init_pubdata_pricing_mode",
            uint256(config.contracts.diamondInitPubdataPricingMode)
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
            "diamond_init_max_l2_gas_per_batch",
            config.contracts.diamondInitMaxL2GasPerBatch
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_priority_tx_max_pubdata",
            config.contracts.diamondInitPriorityTxMaxPubdata
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_minimal_l2_gas_price",
            config.contracts.diamondInitMinimalL2GasPrice
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_node_level_vk_hash",
            config.contracts.recursionNodeLevelVkHash
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_leaf_level_vk_hash",
            config.contracts.recursionLeafLevelVkHash
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_circuits_set_vks_hash",
            config.contracts.recursionCircuitsSetVksHash
        );
        vm.serializeUint("contracts_config", "priority_tx_max_gas_limit", config.contracts.priorityTxMaxGasLimit);
        string memory contractsConfig = vm.serializeBytes(
            "contracts_config",
            "diamond_cut_data",
            config.contracts.diamondCutData
        );

        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);
        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress(
            "deployed_addresses",
            "blob_versioned_hash_retriever_addr",
            addresses.blobVersionedHashRetriever
        );
        vm.serializeAddress("deployed_addresses", "validator_timelock_addr", addresses.validatorTimelock);
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "state_transition", stateTransition);
        string memory deployedAddresses = vm.serializeString("deployed_addresses", "bridges", bridges);

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", config.contracts.create2FactorySalt);
        vm.serializeAddress("root", "multicall3_addr", config.contracts.multicall3Addr);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);
        string memory toml = vm.serializeAddress("root", "owner_addr", config.ownerAddress);

        string memory path = string.concat(vm.projectRoot(), "/script-out/output-deploy-l1.toml");
        vm.writeToml(toml, path);
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.contracts.create2FactorySalt, addresses.create2Factory);
    }
}
