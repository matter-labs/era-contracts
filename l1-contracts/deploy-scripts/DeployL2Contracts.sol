// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    Config internal config;
    ContractsBytecodes internal bytecodes;

    // Contract deployment specification, needed to verify the contract.
    struct ContractSpec {
        address addr;
        string name;
        bytes constructorArgs;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        address governance;
        address erc20BridgeProxy;
        // The owner of the contract sets the validator/attester weights.
        // Can be the developer multisig wallet on mainnet.
        address consensusRegistryOwner;
        uint256 chainId;
        uint256 eraChainId;
        bool legacyBridge;

        bool deploySharedBridge;
        bool deployConsensusRegistry;
        bool deployMulticall3;
        bool deployForceDeployUpgrader;

        ContractSpec l2SharedBridgeImplementation;
        ContractSpec l2SharedBridgeProxy;
        ContractSpec l2ConsensusRegistryImplementation;
        ContractSpec l2ConsensusRegistryProxy;
        ContractSpec l2Multicall3;
        ContractSpec l2ForceDeployUpgrader;
    }

    struct ContractsBytecodes {
        bytes upgradeableBeacon;
        bytes beaconProxy;
        bytes l2StandardErc20;
        bytes l2SharedBridge;
        bytes devL2SharedBridge;
        bytes transparentUpgradeableProxy;
        bytes consensusRegistry;
        bytes multicall3;
        bytes forceDeployUpgrader;
    }

    function deploy() public {
        loadConfig();
        loadContracts();

        if (config.deploySharedBridge) {
            deploySharedBridge();
        }

        if (config.deployConsensusRegistry) {
            deployConsensusRegistry();
        }

        if (config.deployMulticall3) {
            config.l2Multicall3 = deployThroughL1("Multicall3", bytecodes.multicall3, "", new bytes[](0));
        }

        if (config.deployForceDeployUpgrader) {
            config.l2ForceDeployUpgrader = deployThroughL1("ForceDeployUpgrader", bytecodes.forceDeployUpgrader, "", new bytes[](0));
        }

        saveOutput();
    }

    function loadContracts() internal {
        //HACK: Meanwhile we are not integrated foundry zksync we use contracts that has been built using hardhat
        bytecodes.upgradeableBeacon = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/UpgradeableBeacon.sol/UpgradeableBeacon.json"
        );
        bytecodes.beaconProxy = Utils.readFoundryBytecode("/../l2-contracts/zkout/BeaconProxy.sol/BeaconProxy.json");
        bytecodes.l2StandardErc20 = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/L2StandardERC20.sol/L2StandardERC20.json"
        );
        bytecodes.devL2SharedBridge = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/DevL2SharedBridge.sol/DevL2SharedBridge.json"
        );
        bytecodes.l2SharedBridge = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/L2SharedBridge.sol/L2SharedBridge.json"
        );
        bytecodes.transparentUpgradeableProxy = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
        );
        bytecodes.consensusRegistry = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/ConsensusRegistry.sol/ConsensusRegistry.json"
        );
        bytecodes.multicall3 = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/Multicall3.sol/Multicall3.json"
        );
        bytecodes.forceDeployUpgrader = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/ForceDeployUpgrader.sol/ForceDeployUpgrader.json"
        );
    }

    function loadConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2-contracts.toml");
        string memory toml = vm.readFile(path);
        config.legacyBridge = toml.readBool("$.legacy_bridge");
        config.bridgehubAddress = toml.readAddress("$.bridgehub");
        config.governance = toml.readAddress("$.governance");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
        config.consensusRegistryOwner = toml.readAddress("$.consensus_registry_owner");
        config.chainId = toml.readUint("$.chain_id");
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.deploySharedBridge = toml.readBool("$.deploy_shared_bridge");
        config.deployConsensusRegistry = toml.readBool("$.deploy_consensus_registry");
        config.deployMulticall3 = toml.readBool("$.deploy_multicall3");
        config.deployForceDeployUpgrader = toml.readBool("$.deploy_force_deploy_upgrader");
    }

    function serializeContract(ContractSpec memory spec) internal returns (string memory json) {
        vm.serializeAddress("contract_spec", "address", spec.addr);
        vm.serializeString("contract_spec", "name", spec.name);
        return vm.serializeBytes("contract_spec", "constructor_args", spec.constructorArgs);
    }

    function saveOutput() internal {
        string memory toml = "{}";
        if (config.l2SharedBridgeImplementation.addr != address(0)) {
            toml = vm.serializeString("root", "l2_shared_bridge_implementation", serializeContract(config.l2SharedBridgeImplementation));
        }
        if (config.l2SharedBridgeProxy.addr != address(0)) {
            toml = vm.serializeString("root", "l2_shared_bridge_proxy", serializeContract(config.l2SharedBridgeProxy));
        }
        if (config.l2ConsensusRegistryImplementation.addr != address(0)) {
            toml = vm.serializeString("root", "l2_consensus_registry_implementation", serializeContract(config.l2ConsensusRegistryImplementation));
        }
        if (config.l2ConsensusRegistryProxy.addr != address(0)) {
            toml = vm.serializeString("root", "l2_consensus_registry_proxy", serializeContract(config.l2ConsensusRegistryProxy));
        }
        if (config.l2Multicall3.addr != address(0)) {
            toml = vm.serializeString("root", "l2_multicall3", serializeContract(config.l2Multicall3));
        }
        if (config.l2ForceDeployUpgrader.addr != address(0)) {
            toml = vm.serializeString("root", "l2_force_deploy_upgrader", serializeContract(config.l2ForceDeployUpgrader));
        }
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-contracts.toml");
        vm.writeToml(toml, path);
    }

    function deployThroughL1(string memory name, bytes memory bytecode, bytes memory constructorArgs, bytes[] memory factoryDeps) internal returns (ContractSpec memory) {
        address addr = Utils.deployThroughL1({
            bytecode: bytecode,
            constructorargs: constructorArgs,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        return ContractSpec({
            addr: addr,
            name: name,
            constructorArgs: constructorArgs
        });
    }

    function deployTransparentUpgradeableProxy(ContractSpec memory target, address admin, bytes memory data) internal returns (ContractSpec memory) {
        assert(target.addr != address(0));
        assert(admin != address(0));
        bytes memory constructorArgs = abi.encode(target.addr, admin, data);
        return deployThroughL1("TransparentUpgradeableProxy", bytecodes.transparentUpgradeableProxy, constructorArgs, new bytes[](0));
    }

    function deploySharedBridge() internal {
        // Publish relevant factory dependencies.
        bytes[] memory factoryDeps = new bytes[](3);
        factoryDeps[0] = bytecodes.upgradeableBeacon;
        factoryDeps[1] = bytecodes.l2StandardErc20;
        factoryDeps[2] = bytecodes.beaconProxy;
        Utils.publishBytecodes(factoryDeps, config.chainId, config.bridgehubAddress, config.l1SharedBridgeProxy);

        // Deploy the shared bridge contract.
        factoryDeps = new bytes[](1);
        factoryDeps[0] = bytecodes.beaconProxy;
        bytes memory constructorArgs = abi.encode(config.eraChainId);
        string memory functionSignature;
        if (config.legacyBridge) {
            config.l2SharedBridgeImplementation = deployThroughL1("DevL2SharedBridge", bytecodes.devL2SharedBridge, constructorArgs, factoryDeps);
            functionSignature = "initializeDevBridge(address,address,bytes32,address)";
        } else {
            config.l2SharedBridgeImplementation = deployThroughL1("L2SharedBridge", bytecodes.l2SharedBridge, constructorArgs, factoryDeps);
            functionSignature = "initialize(address,address,bytes32,address)";
        }

        // Deploy proxy to the shared bridge.
        address l2GovernorAddress = AddressAliasHelper.applyL1ToL2Alias(config.governance);
        config.l2SharedBridgeProxy = deployTransparentUpgradeableProxy(
            config.l2SharedBridgeImplementation,
            l2GovernorAddress,
            abi.encodeWithSignature(
                functionSignature,
                config.l1SharedBridgeProxy,
                config.erc20BridgeProxy,
                L2ContractHelper.hashL2Bytecode(bytecodes.beaconProxy),
                l2GovernorAddress
            )
        );

        // Initialize the chain.
        L1SharedBridge bridge = L1SharedBridge(config.l1SharedBridgeProxy);
        if (bridge.l2BridgeAddress(config.chainId) == address(0)) {
            Utils.chainAdminMulticall({
                _chainAdmin: bridge.admin(),
                _target: config.l1SharedBridgeProxy,
                _data: abi.encodeCall(bridge.initializeChainGovernance, (config.chainId, config.l2SharedBridgeProxy.addr)),
                _value: 0
            });
        }
    }

    // Deploy a transparent upgradable proxy for the already deployed consensus registry
    // implementation and save its address into the config.
    function deployConsensusRegistry() internal {
        config.l2ConsensusRegistryImplementation = deployThroughL1("ConsensusRegistry", bytecodes.consensusRegistry, "", new bytes[](0));
        config.l2ConsensusRegistryProxy = deployTransparentUpgradeableProxy(
            config.l2ConsensusRegistryImplementation,
            AddressAliasHelper.applyL1ToL2Alias(config.governance),
            abi.encodeWithSignature(
                "initialize(address)",
                config.consensusRegistryOwner
            )
        );
    }
}
