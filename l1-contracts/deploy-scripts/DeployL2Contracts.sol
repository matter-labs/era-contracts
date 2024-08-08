pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    Config internal config;
    ContractsBytecodes internal contracts;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        bool validiumMode;
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        address governance;
        address erc20BridgeProxy;
        uint256 chainId;
        uint256 eraChainId;
        address l2SharedBridgeImplementation;
        address l2SharedBridgeProxy;
        address forceDeployUpgraderAddress;
        address l1DAValidatorAddress;
        address l2DAValidatorAddress;
        address chainAdmin;
        address diamondProxyAddr;
    }

    struct ContractsBytecodes {
        bytes l2StandardErc20FactoryBytecode;
        bytes beaconProxy;
        bytes l2StandardErc20Bytecode;
        bytes l2SharedBridgeBytecode;
        bytes l2SharedBridgeProxyBytecode;
        bytes forceDeployUpgrader;
        bytes l2RollupDAValidator;
        bytes l2ValidiumDAValidator;
    }

    function run() public {
        initializeConfig();
        loadContracts();

        // This function MUST be the first one to be called here.
        // The L2 DA validator must be ready to use at the end of the first batch itself.
        deployAndRegisterL2DaValidator();

        deployFactoryDeps();
        deploySharedBridge();
        deploySharedBridgeProxy();
        deployForceDeployer();

        saveOutput();
    }

    function runDeploySharedBridge() public {
        initializeConfig();
        loadContracts();

        deployFactoryDeps();
        deploySharedBridge();
        deploySharedBridgeProxy();

        saveOutput();
    }

    function runDefaultUpgrader() public {
        initializeConfig();
        loadContracts();

        deployForceDeployer();

        saveOutput();
    }

    function loadContracts() internal {
        //HACK: Meanwhile we are not integrated foundry zksync we use contracts that has been built using hardhat
        contracts.l2StandardErc20FactoryBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol/UpgradeableBeacon.json"
        );
        contracts.beaconProxy = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
        );
        contracts.l2StandardErc20Bytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2StandardERC20.sol/L2StandardERC20.json"
        );

        contracts.l2SharedBridgeBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2AssetRouter.sol/L2AssetRouter.json"
        );

        contracts.l2RollupDAValidator = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/data-availability/RollupL2DAValidator.sol/RollupL2DAValidator.json"
        );

        contracts.l2ValidiumDAValidator = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/data-availability/ValidiumL2DAValidator.sol/ValidiumL2DAValidator.json"
        );

        contracts.l2SharedBridgeProxyBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
        );
        contracts.forceDeployUpgrader = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/ForceDeployUpgrader.sol/ForceDeployUpgrader.json"
        );
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2-contracts.toml");
        string memory toml = vm.readFile(path);
        config.bridgehubAddress = toml.readAddress("$.bridgehub");
        config.governance = toml.readAddress("$.governance");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
        config.chainId = toml.readUint("$.chain_id");
        config.diamondProxyAddr = toml.readUint("$.diamond_proxy_addr");
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.validiumMode = toml.readBool("$.validium_mode");
        config.l1DAValidatorAddress = toml.readAddress("$.l1_da_validator");
        config.chainAdmin = toml.readBool("$.chain_admin");
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "l2_shared_bridge_implementation", config.l2SharedBridgeImplementation);
        vm.serializeAddress("root", "l2_shared_bridge_proxy", config.l2SharedBridgeProxy);
        vm.serializeAddress("root", "l2_da_validator_addr", config.l2DAValidatorAddress);
        string memory toml = vm.serializeAddress("root", "l2_default_upgrader", config.forceDeployUpgraderAddress);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-contracts.toml");
        vm.writeToml(toml, path);
    }

    function deployAndRegisterL2DaValidator() internal {
        address l2Validator;
        if (config.validiumMode) {
            l2Validator = Utils.deployThroughL1({
                bytecode: contracts.l2ValidiumDAValidator,
                constructorargs: new bytes(),
                create2salt: "",
                l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
                factoryDeps: factoryDeps,
                chainId: config.chainId,
                bridgehubAddress: config.bridgehubAddress,
                l1SharedBridgeProxy: config.l1SharedBridgeProxy
            });
        } else {
            l2Validator = Utils.deployThroughL1({
                bytecode: contracts.l2RollupDAValidator,
                constructorargs: new bytes(),
                create2salt: "",
                l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
                factoryDeps: factoryDeps,
                chainId: config.chainId,
                bridgehubAddress: config.bridgehubAddress,
                l1SharedBridgeProxy: config.l1SharedBridgeProxy
            });
        }

        config.l2DAValidatorAddress = l2Validator;

        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: config.diamondProxyAddr, value: 0, data: abi.encodeCall(hyperchain.setDAValidatorPair, (config.l1DAValidatorAddress, config.l2DAValidatorAddress))});

        vm.startBroadcast();
        IChainAdmin(config.chainAdmin).multicall(calls, true);
        vm.stopBroadcast();   
    }

    function deployFactoryDeps() internal {
        bytes[] memory factoryDeps = new bytes[](3);
        factoryDeps[0] = contracts.l2StandardErc20FactoryBytecode;
        factoryDeps[1] = contracts.l2StandardErc20Bytecode;
        factoryDeps[2] = contracts.beaconProxy;
        Utils.publishBytecodes(factoryDeps, config.chainId, config.bridgehubAddress, config.l1SharedBridgeProxy);
    }

    function deploySharedBridge() internal {
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

    function deployForceDeployer() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        config.forceDeployUpgraderAddress = Utils.deployThroughL1({
            bytecode: contracts.forceDeployUpgrader,
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deploySharedBridgeProxy() internal {
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
}
