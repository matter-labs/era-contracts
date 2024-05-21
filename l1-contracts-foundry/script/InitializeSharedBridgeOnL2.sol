pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    Config config;
    ContractsBytecodes contracts;

    struct Config {
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        address governance;
        address erc20BridgeProxy;
        uint256 chainId;
        uint256 eraChainId;
        address l2SharedBridgeImplementation;
        address l2SharedBridgeProxy;
    }

    struct ContractsBytecodes {
        bytes l2StandardErc20FactoryBytecode;
        bytes beaconProxy;
        bytes l2StandardErc20Bytecode;
        bytes l2SharedBridgeBytecode;
        bytes l2SharedBridgeProxyBytecode;
    }

    function run() public {
        initializeConfig();
        loadContracts();

        deployFactoryDeps();
        deploySharedBridge();
        deploySharedBridgeProxy();
        initializeChain();

        saveOutput();
    }

    function loadContracts() internal {
        contracts.l2StandardErc20FactoryBytecode = Utils.readForgeBytecode(
            "/../l2-contracts/zkout/UpgradeableBeacon.sol/artifacts.json",
            "node_modules/@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol"
        );
        contracts.beaconProxy = Utils.readForgeBytecode(
            "/../l2-contracts/zkout/BeaconProxy.sol/artifacts.json",
            "node_modules/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol"
        );
        contracts.l2StandardErc20Bytecode = Utils.readForgeBytecode(
            "/../l2-contracts/zkout/L2StandardERC20.sol/artifacts.json",
            "contracts/bridge/L2StandardERC20.sol"
        );
        contracts.l2SharedBridgeBytecode = Utils.readForgeBytecode(
            "/../l2-contracts/zkout/L2SharedBridge.sol/artifacts.json",
            "contracts/bridge/L2SharedBridge.sol"
        );
        contracts.l2SharedBridgeProxyBytecode = Utils.readForgeBytecode(
            "/../l2-contracts/zkout/TransparentUpgradeableProxy.sol/artifacts.json",
            "node_modules/@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol"
        );
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-initialize-shared-bridges.toml");
        string memory toml = vm.readFile(path);
        config.bridgehubAddress = toml.readAddress("$.bridgehub");
        config.governance = toml.readAddress("$.governance");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
        config.chainId = toml.readUint("$.chain_id");
        config.eraChainId = toml.readUint("$.era_chain_id");
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "l2_shared_bridge_implementation", config.l2SharedBridgeImplementation);
        string memory toml = vm.serializeAddress("root", "l2_shared_bridge_proxy", config.l2SharedBridgeProxy);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-initialize-shared-bridges.toml");
        vm.writeToml(toml, path);
    }

    function deployFactoryDeps() public {
        bytes[] memory factoryDeps = new bytes[](3);
        factoryDeps[0] = contracts.l2StandardErc20FactoryBytecode;
        factoryDeps[1] = contracts.l2StandardErc20Bytecode;
        factoryDeps[2] = contracts.beaconProxy;
        Utils.publishBytecodes(factoryDeps, config.chainId, config.bridgehubAddress, config.l1SharedBridgeProxy);
    }

    function deploySharedBridge() public {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = contracts.beaconProxy;

        bytes memory constructorData = abi.encode(config.eraChainId);

        config.l2SharedBridgeImplementation = Utils.deployThroughL1({
            bytecode: contracts.l2SharedBridgeBytecode,
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deploySharedBridgeProxy() public {
        address l2GovernorAddress = AddressAliasHelper.applyL1ToL2Alias(config.governance);
        bytes32 l2StandardErc20BytecodeHash = L2ContractHelper.hashL2Bytecode(contracts.beaconProxy);

        // solhint-disable-next-line func-named-parameters
        bytes memory proxyInitializationParams = abi.encodeWithSignature(
            "initialize(address,address,bytes32,address)",
            config.l1SharedBridgeProxy,
            config.erc20BridgeProxy,
            l2StandardErc20BytecodeHash,
            l2GovernorAddress
        );

        bytes memory l2SharedBridgeProxyConstructorData = abi.encode(
            config.l2SharedBridgeImplementation,
            l2GovernorAddress,
            proxyInitializationParams
        );

        config.l2SharedBridgeProxy = Utils.deployThroughL1({
            bytecode: contracts.l2SharedBridgeProxyBytecode,
            constructorargs: l2SharedBridgeProxyConstructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function initializeChain() public {
        L1SharedBridge bridge = L1SharedBridge(config.l1SharedBridgeProxy);

        Utils.executeUpgrade({
            _governor: bridge.owner(),
            _salt: bytes32(0),
            _target: config.l1SharedBridgeProxy,
            _data: abi.encodeCall(bridge.initializeChainGovernance, (config.chainId, config.l2SharedBridgeProxy)),
            _value: 0,
            _delay: 0
        });
    }
}
