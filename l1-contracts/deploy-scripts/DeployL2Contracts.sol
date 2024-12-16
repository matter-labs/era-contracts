// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
// import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    Config internal config;
    DeployedContrats internal deployed;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 eraChainId;
        uint256 chainId;
        address l1SharedBridgeProxy;
        address bridgehubAddress;
        address governance;
        address erc20BridgeProxy;
        bool validiumMode;
        address consensusRegistryOwner;
    }

    struct DeployedContrats {
        address l2DaValidatorAddress;
        address forceDeployUpgraderAddress;
        address consensusRegistryImplementation;
        address consensusRegistryProxy;
        address multicall3;
    }

    function run() public {
        deploy(false);
    }

    function runWithLegacyBridge() public {
        deploy(true);
    }

    function deploy(bool legacyBridge) public {
        initializeConfig();

        // Note, that it is important that the first transaction is for setting the L2 DA validator
        deployL2DaValidator();

        deployForceDeployer();
        deployConsensusRegistry();
        deployConsensusRegistryProxy();
        deployMulticall3();

        saveOutput();
    }

    function runDeployLegacySharedBridge() public {
        deploySharedBridge(true);
    }

    function runDeploySharedBridge() public {
        deploySharedBridge(false);
    }

    // TODO(EVM-745): port legacy contract tests to new contracts
    function deploySharedBridge(bool legacyBridge) internal {
        initializeConfig();

        saveOutput();
    }

    function runDefaultUpgrader() public {
        initializeConfig();

        deployForceDeployer();

        saveOutput();
    }

    function runDeployConsensusRegistry() public {
        initializeConfig();

        deployConsensusRegistry();
        deployConsensusRegistryProxy();

        saveOutput();
    }

    function runDeployMulticall3() public {
        initializeConfig();

        deployMulticall3();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2-contracts.toml");
        string memory toml = vm.readFile(path);
        config.validiumMode = toml.readBool("$.validium_mode");
        config.bridgehubAddress = toml.readAddress("$.bridgehub");
        config.governance = toml.readAddress("$.governance");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
        config.consensusRegistryOwner = toml.readAddress("$.consensus_registry_owner");
        config.chainId = toml.readUint("$.chain_id");
        config.eraChainId = toml.readUint("$.era_chain_id");
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "l2_da_validator_address", deployed.l2DaValidatorAddress);
        vm.serializeAddress("root", "multicall3", deployed.multicall3);
        vm.serializeAddress("root", "consensus_registry_implementation", deployed.consensusRegistryImplementation);
        vm.serializeAddress("root", "consensus_registry_proxy", deployed.consensusRegistryProxy);
        string memory toml = vm.serializeAddress("root", "l2_default_upgrader", deployed.forceDeployUpgraderAddress);

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-contracts.toml");
        vm.writeToml(toml, path);
    }

    function deployL2DaValidator() internal {
        bytes memory bytecode;
        if (config.validiumMode) {
            bytecode = L2ContractsBytecodesLib.readValidiumL2DAValidatorBytecode();
        } else {
            bytecode = L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode();
        }

        deployed.l2DaValidatorAddress = Utils.deployThroughL1Deterministic({
            bytecode: bytecode,
            constructorargs: bytes(""),
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deployForceDeployer() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        deployed.forceDeployUpgraderAddress = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readForceDeployUpgraderBytecode(),
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    // Deploy the ConsensusRegistry implementation and save its address into the config.
    function deployConsensusRegistry() internal {
        // ConsensusRegistry.sol doesn't have a constructor, just an initializer.
        bytes memory constructorData = "";

        deployed.consensusRegistryImplementation = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readConsensusRegistryBytecode(),
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deployMulticall3() internal {
        // Multicall3 doesn't have a constructor.
        bytes memory constructorData = "";

        deployed.multicall3 = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readMulticall3Bytecode(),
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    // Deploy a transparent upgradable proxy for the already deployed consensus registry
    // implementation and save its address into the config.
    function deployConsensusRegistryProxy() internal {
        // Admin for the proxy
        address l2GovernorAddress = AddressAliasHelper.applyL1ToL2Alias(config.governance);

        // Call ConsensusRegistry::initialize with the initial owner.
        // solhint-disable-next-line func-named-parameters
        bytes memory proxyInitializationParams = abi.encodeWithSignature(
            "initialize(address)",
            config.consensusRegistryOwner
        );

        bytes memory consensusRegistryProxyConstructorData = abi.encode(
            deployed.consensusRegistryImplementation, // _logic
            l2GovernorAddress, // admin_
            proxyInitializationParams // _data
        );

        deployed.consensusRegistryProxy = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecode(),
            constructorargs: consensusRegistryProxyConstructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }
}
