pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehub.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    uint256 constant MAX_PRIORITY_TX_GAS = 72000000;
    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
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
        initialize_chain();

        saveOutput();
    }


    function loadContracts() internal {
        //HACK: Meanwhile we are not integrated foundry zksync we use contracts that has been built using hardhat
        contracts.l2StandardErc20FactoryBytecode = readHardheadBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol/UpgradeableBeacon.json"
        );
        contracts.beaconProxy = readHardheadBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
        );
        contracts.l2StandardErc20Bytecode = readHardheadBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2StandardERC20.sol/L2StandardERC20.json"
        );

        contracts.l2SharedBridgeBytecode = readHardheadBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2SharedBridge.sol/L2SharedBridge.json"
        );

        contracts.l2SharedBridgeProxyBytecode = readHardheadBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
        );
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2.toml");
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
        string memory path = string.concat(root, "/script-out/output-deploy-l2.toml");
        vm.writeToml(toml, path);
    }

    function readHardheadBytecode(string memory artifactPath) public returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, artifactPath);
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode");
        return bytecode;
    }

    function deployFactoryDeps() public {
        bytes[] memory factoryDeps = new bytes[](3);
        factoryDeps[0] = contracts.l2StandardErc20FactoryBytecode;
        factoryDeps[1] = contracts.l2StandardErc20Bytecode;
        factoryDeps[2] = contracts.beaconProxy;
        publishBytecodes(factoryDeps);
    }

    function deploySharedBridge() public {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = contracts.beaconProxy;

        bytes memory constructorData = abi.encode(config.eraChainId);
        config.l2SharedBridgeImplementation = L2ContractHelper.computeCreate2Address(
            msg.sender,
            "",
            L2ContractHelper.hashL2Bytecode(contracts.l2SharedBridgeBytecode),
            keccak256(constructorData)
        );

        deployThroughL1({
            bytecode: contracts.l2SharedBridgeBytecode,
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps
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

        bytes32 l2SharedBridgeProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(contracts.l2SharedBridgeProxyBytecode);
        config.l2SharedBridgeProxy = L2ContractHelper.computeCreate2Address(
            msg.sender,
            "",
            l2SharedBridgeProxyBytecodeHash,
            keccak256(l2SharedBridgeProxyConstructorData)
        );

        deployThroughL1({
            bytecode: contracts.l2SharedBridgeProxyBytecode,
            constructorargs: l2SharedBridgeProxyConstructorData,
            create2salt: "",
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0)
        });
    }

    function publishBytecodes(bytes[] memory factoryDeps) public {
        runL1L2Transaction("", MAX_PRIORITY_TX_GAS, factoryDeps, 0x0000000000000000000000000000000000000000);
    }

    function deployThroughL1(
        bytes memory bytecode,
        bytes memory constructorargs,
        bytes32 create2salt,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps
    ) public {
        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        bytes memory deployData = abi.encodeWithSignature(
            "create2(bytes32,bytes32,bytes)",
            create2salt,
            bytecodeHash,
            constructorargs
        );

        bytes[] memory _factoryDeps = new bytes[](factoryDeps.length + 1);

        for (uint256 i = 0; i < factoryDeps.length; i++) {
            _factoryDeps[i] = factoryDeps[i];
        }
        _factoryDeps[factoryDeps.length] = bytecode;

        runL1L2Transaction(deployData, l2GasLimit, _factoryDeps, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
    }

    function runL1L2Transaction(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        address dstAddress
    ) public {
        Bridgehub bridgehub = Bridgehub(config.bridgehubAddress);
        uint256 gasPrice = Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]"));

        uint256 requiredValueToDeploy = bridgehub.l2TransactionBaseCost(
            config.chainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        L2TransactionRequestDirect memory l2TransactionRequestDirect = L2TransactionRequestDirect({
            chainId: config.chainId,
            mintValue: requiredValueToDeploy,
            l2Contract: dstAddress,
            l2Value: 0,
            l2Calldata: l2Calldata,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: factoryDeps,
            refundRecipient: msg.sender
        });

        vm.startBroadcast();
        address baseTokenAddress = bridgehub.baseToken(config.chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            IERC20 baseToken = IERC20(baseTokenAddress);
            baseToken.approve(config.l1SharedBridgeProxy, requiredValueToDeploy * 2);
            requiredValueToDeploy = 0;
        }

        bridgehub.requestL2TransactionDirect{value: requiredValueToDeploy}(l2TransactionRequestDirect);

        vm.stopBroadcast();
    }

    function initialize_chain() public {
        L1SharedBridge bridge = L1SharedBridge(config.l1SharedBridgeProxy);
        vm.broadcast();
        bridge.initializeChainGovernance(config.chainId, config.l2SharedBridgeProxy);
    }
}
