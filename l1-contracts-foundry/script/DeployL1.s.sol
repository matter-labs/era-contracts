// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// solhint-disable no-console

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Script} from "./Script.sol";
import {Utils} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {SingletonFactory} from "contracts/dev-contracts/SingletonFactory.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData} from "contracts/state-transition/IStateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeData as DiamondInitInitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";

contract DeployL1Script is Script {
    using stdToml for string;

    struct DeployedAddresses {
        BridgehubDeployedAddresses bridgehub;
        StateTransitionDeployedAddresses stateTransition;
        BridgesDeployedAddresses bridges;
        address transparentProxyAdmin;
        address governance;
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
        address deployerAddress;
        uint256 gasPrice;
        ContractsConfig contracts;
        TokensConfig tokens;
    }

    struct ContractsConfig {
        bytes32 create2_factory_salt;
        address create2_factory_addr;
        uint256 validator_timelock_execution_delay;
        bytes32 genesis_root;
        uint256 genesis_rollup_leaf_index;
        bytes32 genesis_batch_commitment;
        uint256 latest_protocol_version;
        bytes32 recursion_node_level_vk_hash;
        bytes32 recursion_leaf_level_vk_hash;
        bytes32 recursion_circuits_set_vks_hash;
        uint256 priority_tx_max_gas_limit;
        uint256 shared_bridge_upgrade_storage_switch;
    }

    struct TokensConfig {
        address token_weth_address;
    }

    Config config;
    DeployedAddresses addresses;

    function run() public {
        console.log("Deploying L1 contracts");

        initializeConfig();

        deployOrInstantiateCreate2Factory();
        deployIfNeededMulticall3();

        deployVerifier();

        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployValidatorTimelock();

        deployGovernance();
        deployTransparentProxyAdmin();
        deployBridgehubContract();
        deployBlobVersionedHashRetriever();
        deployStateTransitionManagerContract();
        setStateTransitionManagerInValidatorTimelock();

        deployDiamondProxy();

        deployErc20BridgeProxy();
        deploySharedBridgeContracts();
        deployErc20BridgeImplementation();
        upgradeL1Erc20Bridge();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l1.toml");
        string memory toml = vm.readFile(path);

        chainId = block.chainid;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.deployerAddress = msg.sender;
        config.gasPrice = toml.readUint("$.gas_price");

        config.contracts.create2_factory_salt = toml.readBytes32("$.contracts.create2_factory_salt");
        config.contracts.create2_factory_addr = toml.readAddress("$.contracts.create2_factory_addr");
        config.contracts.validator_timelock_execution_delay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.genesis_root = toml.readBytes32("$.contracts.genesis_root");
        config.contracts.genesis_rollup_leaf_index = toml.readUint("$.contracts.genesis_rollup_leaf_index");
        config.contracts.genesis_batch_commitment = toml.readBytes32("$.contracts.genesis_batch_commitment");
        config.contracts.latest_protocol_version = toml.readUint("$.contracts.latest_protocol_version");
        config.contracts.recursion_node_level_vk_hash = toml.readBytes32("$.contracts.recursion_node_level_vk_hash");
        config.contracts.recursion_leaf_level_vk_hash = toml.readBytes32("$.contracts.recursion_leaf_level_vk_hash");
        config.contracts.recursion_circuits_set_vks_hash = toml.readBytes32(
            "$.contracts.recursion_circuits_set_vks_hash"
        );
        config.contracts.priority_tx_max_gas_limit = toml.readUint("$.contracts.priority_tx_max_gas_limit");
        config.contracts.shared_bridge_upgrade_storage_switch = toml.readUint(
            "$.contracts.shared_bridge_upgrade_storage_switch"
        );

        config.tokens.token_weth_address = toml.readAddress("$.tokens.token_weth_address");
    }

    function deployOrInstantiateCreate2Factory() internal returns (address) {
        // Create2Factory is already deployed on the public networks
        address contractAddress;
        if (isNetworkLocal()) {
            vm.broadcast();
            SingletonFactory factory = new SingletonFactory();
            contractAddress = address(factory);
            console.log("Create2Factory deployed at:", contractAddress);
        } else {
            contractAddress = config.contracts.create2_factory_addr;
            console.log("Using Create2Factory address:", contractAddress);
        }
        addresses.create2Factory = contractAddress;
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on the public networks
        if (isNetworkLocal()) {
            address contractAddress = deployViaCreate2(type(Multicall3).creationCode);
            console.log("Multicall3 deployed at:", contractAddress);
        }
    }

    function deployVerifier() internal {
        address contractAddress = deployViaCreate2(type(Verifier).creationCode);
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
        uint32 executionDelay = uint32(config.contracts.validator_timelock_execution_delay);
        bytes memory bytecode = abi.encodePacked(
            type(ValidatorTimelock).creationCode,
            abi.encode(config.deployerAddress, executionDelay, chainId)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ValidatorTimelock deployed at:", contractAddress);
        addresses.validatorTimelock = contractAddress;
    }

    function deployGovernance() internal {
        bytes memory bytecode = abi.encodePacked(
            type(Governance).creationCode,
            abi.encode(config.deployerAddress, address(0), uint256(0))
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Governance deployed at:", contractAddress);
        addresses.governance = contractAddress;
    }

    function deployTransparentProxyAdmin() internal {
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        proxyAdmin.transferOwnership(addresses.governance);
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
        address contractAddress = deployViaCreate2(abi.encode(bytecode));
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

        address mailboxFacet = deployViaCreate2(abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(chainId)));
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
            abi.encode(addresses.bridgehub.bridgehubProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("StateTransitionManagerImplementation deployed at:", contractAddress);
        addresses.stateTransition.stateTransitionImplementation = contractAddress;
    }

    function deployStateTransitionManagerProxy() internal {
        bytes32 genesisBatchHash = config.contracts.genesis_root;
        uint256 genesisRollupLeafIndex = config.contracts.genesis_rollup_leaf_index;
        bytes32 genesisBatchCommitment = config.contracts.genesis_batch_commitment;
        uint256 protocolVersion = config.contracts.latest_protocol_version;

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
            recursionNodeLevelVkHash: config.contracts.recursion_node_level_vk_hash,
            recursionLeafLevelVkHash: config.contracts.recursion_leaf_level_vk_hash,
            recursionCircuitsSetVksHash: config.contracts.recursion_circuits_set_vks_hash
        });

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 120_000,
            maxL2GasPerBatch: 80000000,
            priorityTxMaxPubdata: 99000,
            minimalL2GasPrice: 250000000
        });

        DiamondInitInitializeData memory initializeData = DiamondInitInitializeData({
            chainId: 1,
            bridgehub: address(0x1234),
            stateTransitionManager: address(0x2234),
            protocolVersion: 0x2234,
            admin: address(0x3234),
            validatorTimelock: address(0x4234),
            baseToken: address(0x4234),
            baseTokenBridge: address(0x4234),
            storedBatchZero: hex"5432",
            verifier: IVerifier(addresses.stateTransition.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: bytes32(getBatchBootloaderBytecodeHash()),
            l2DefaultAccountBytecodeHash: bytes32(readSystemContractsBytecode("DefaultAccount")),
            priorityTxMaxGasLimit: config.contracts.priority_tx_max_gas_limit,
            feeParams: feeParams,
            blobVersionedHashRetriever: addresses.blobVersionedHashRetriever
        });
        bytes memory initCallData = abi.encodeCall(DiamondInit.initialize, (initializeData));

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.stateTransition.diamondInit,
            initCalldata: initCallData
        });

        StateTransitionManagerInitializeData memory diamondInitData = StateTransitionManagerInitializeData({
            governor: config.deployerAddress,
            validatorTimelock: addresses.validatorTimelock,
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: genesisBatchHash,
            genesisIndexRepeatedStorageChanges: uint64(genesisRollupLeafIndex),
            genesisBatchCommitment: genesisBatchCommitment,
            diamondCut: diamondCut,
            protocolVersion: protocolVersion
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
            initCalldata: hex""
        });
        bytes memory bytecode = abi.encodePacked(type(DiamondProxy).creationCode, abi.encode(chainId, diamondCut));
        address contractAddress = deployViaCreate2(bytecode);
        console.log("DiamondProxy deployed at:", contractAddress);
        addresses.stateTransition.diamondProxy = contractAddress;
    }

    function deployErc20BridgeProxy() internal {
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy, addresses.transparentProxyAdmin, bytes(hex""))
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Erc20BridgeProxy deployed at:", contractAddress);
        addresses.bridges.erc20BridgeProxy = contractAddress;
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
                config.tokens.token_weth_address,
                addresses.bridgehub.bridgehubProxy,
                addresses.bridges.erc20BridgeProxy,
                chainId,
                addresses.bridges.erc20BridgeImplementation,
                addresses.stateTransition.diamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeImplementation deployed at:", contractAddress);
        addresses.bridges.sharedBridgeImplementation = contractAddress;
    }

    function deploySharedBridgeProxy() internal {
        uint256 storageSwitch = config.contracts.shared_bridge_upgrade_storage_switch;
        bytes memory initCalldata = abi.encodeCall(L1SharedBridge.initialize, (addresses.governance, storageSwitch));
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
        bridgehub.addToken(address(0x01));
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

    function upgradeL1Erc20Bridge() internal {
        // In local network, we need to change the block.number
        // as the operation could be scheduled for timestamp 1
        // which is also a magic number meaning the operation
        // is done.
        if (isNetworkLocal()) {
            vm.warp(10);
        }

        bytes memory callData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(addresses.bridges.erc20BridgeProxy),
                addresses.bridges.erc20BridgeImplementation,
                abi.encodeCall(L1ERC20Bridge.initialize, ())
            )
        );

        IGovernance.Call[] memory calls = new IGovernance.Call[](1);
        calls[0] = IGovernance.Call({target: addresses.transparentProxyAdmin, value: 0, data: callData});

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        Governance governance = Governance(payable(addresses.governance));

        vm.startBroadcast();
        governance.scheduleTransparent(operation, 0);
        governance.execute(operation);
        vm.stopBroadcast();
        console.log("L1Erc20Bridge upgraded");
    }

    function saveOutput() internal {
        vm.serializeAddress("l1", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);
        vm.serializeAddress("l1", "governance_addr", addresses.governance);
        vm.serializeAddress("l1", "blob_versioned_hash_retriever_addr", addresses.blobVersionedHashRetriever);
        vm.serializeAddress("l1", "validator_timelock_addr", addresses.validatorTimelock);
        vm.serializeAddress("l1", "create2_factory_addr", addresses.create2Factory);

        vm.serializeAddress("l1.bridgehub", "bridgehub_proxy_addr", addresses.bridgehub.bridgehubProxy);
        string memory l1Bridgehub = vm.serializeAddress(
            "l1.bridgehub",
            "bridgehub_implementation_addr",
            addresses.bridgehub.bridgehubImplementation
        );

        vm.serializeAddress(
            "l1.state_transition",
            "state_transition_proxy_addr",
            addresses.stateTransition.stateTransitionProxy
        );
        vm.serializeAddress(
            "l1.state_transition",
            "state_transition_implementation_addr",
            addresses.stateTransition.stateTransitionImplementation
        );
        vm.serializeAddress("l1.state_transition", "verifier_addr", addresses.stateTransition.verifier);
        vm.serializeAddress("l1.state_transition", "admin_facet_addr", addresses.stateTransition.adminFacet);
        vm.serializeAddress("l1.state_transition", "mailbox_facet_addr", addresses.stateTransition.mailboxFacet);
        vm.serializeAddress("l1.state_transition", "executor_facet_addr", addresses.stateTransition.executorFacet);
        vm.serializeAddress("l1.state_transition", "getters_facet_addr", addresses.stateTransition.gettersFacet);
        vm.serializeAddress("l1.state_transition", "diamond_init_addr", addresses.stateTransition.diamondInit);
        vm.serializeAddress("l1.state_transition", "genesis_upgrade_addr", addresses.stateTransition.genesisUpgrade);
        vm.serializeAddress("l1.state_transition", "default_upgrade_addr", addresses.stateTransition.defaultUpgrade);
        string memory l1StateTransition = vm.serializeAddress(
            "l1.state_transition",
            "diamond_proxy_addr",
            addresses.stateTransition.diamondProxy
        );

        vm.serializeAddress(
            "l1.bridges",
            "erc20_bridge_implementation_addr",
            addresses.bridges.erc20BridgeImplementation
        );
        vm.serializeAddress("l1.bridges", "erc20_bridge_proxy_addr", addresses.bridges.erc20BridgeProxy);
        vm.serializeAddress(
            "l1.bridges",
            "shared_bridge_implementation_addr",
            addresses.bridges.sharedBridgeImplementation
        );
        string memory l1Bridges = vm.serializeAddress(
            "l1.bridges",
            "shared_bridge_proxy_addr",
            addresses.bridges.sharedBridgeProxy
        );

        vm.serializeUint("l1", "chain_id", chainId);
        vm.serializeString("l1", "bridgehub", l1Bridgehub);
        vm.serializeString("l1", "state_transition", l1StateTransition);
        vm.serializeAddress("l1", "deployer_addr", config.deployerAddress);
        string memory l1 = vm.serializeString("l1", "bridges", l1Bridges);

        string memory toml = vm.serializeString("toml", "l1", l1);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l1.toml");
        vm.writeToml(toml, path);
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        if (_bytecode.length == 0) {
            revert("Bytecode is not set");
        }

        address contractAddress = computeCreate2Address(
            config.contracts.create2_factory_salt,
            keccak256(_bytecode),
            addresses.create2Factory
        );
        if (contractAddress.code.length != 0) {
            return contractAddress;
        }

        SingletonFactory create2Factory = SingletonFactory(addresses.create2Factory);
        vm.broadcast();
        contractAddress = create2Factory.deploy(_bytecode, config.contracts.create2_factory_salt);

        if (contractAddress == address(0)) {
            revert("Failed to deploy contract via create2");
        }

        return contractAddress;
    }

    function getBatchBootloaderBytecodeHash() internal view returns (bytes memory) {
        return vm.readFileBinary("../system-contracts/bootloader/build/artifacts/proved_batch.yul.zbin");
    }

    function readSystemContractsBytecode(string memory filename) internal view returns (bytes memory) {
        string memory file = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat(
                "../system-contracts/artifacts-zk/contracts-preprocessed/",
                filename,
                ".sol/",
                filename,
                ".json"
            )
        );
        bytes memory bytecode = vm.parseJson(file, "$.bytecode");
        return bytecode;
    }
}
