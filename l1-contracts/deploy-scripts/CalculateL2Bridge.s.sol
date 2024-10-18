// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils} from "./Utils.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

contract CalculateL2Bridge is Script {
    using stdToml for string;

    Config config;
    ContractsBytecodes contracts;

    struct Config {
        address l1SharedBridgeProxy;
        address governance;
        address erc20BridgeProxy;
        address sender;
        uint256 chainId;
        uint256 eraChainId;
    }

    struct ContractsBytecodes {
        bytes l2StandardErc20FactoryBytecode;
        bytes beaconProxy;
        bytes l2StandardErc20Bytecode;
        bytes l2SharedBridgeBytecode;
        bytes l2SharedBridgeProxyBytecode;
        bytes proxyAdminBytecode;
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
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2SharedBridge.sol/L2SharedBridge.json"
        );

        contracts.l2SharedBridgeProxyBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
        );
        contracts.proxyAdminBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol/ProxyAdmin.json"
        );

    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/calculate.toml");
        string memory toml = vm.readFile(path);
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.sender = toml.readAddress("$.sender");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
    }

    function run() public {
        initializeConfig();
        loadContracts();
        address implAddr = sharedBridgeImplementation();
        address proxyAdmin = proxyAdminAddr();
        sharedBridgeProxyAddr(implAddr, proxyAdmin);

    }

    function calcualateAddress(
        address sender,
        bytes memory bytecode,
        bytes memory constructorargs,
        bytes32 create2salt
    ) internal returns (address) {

        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        console.log("BytecodeHash");
        console.logBytes32(bytecodeHash);
        console.log("constructorargs");
        console.logBytes(constructorargs);
        bytes memory deployData = abi.encodeWithSignature(
            "create2(bytes32,bytes32,bytes)",
            create2salt,
            bytecodeHash,
            constructorargs
        );

        address contractAddress = L2ContractHelper.computeCreate2Address(
            sender,
            create2salt,
            bytecodeHash,
            keccak256(constructorargs)
        );
        return contractAddress;
    }

    function sharedBridgeImplementation() internal returns (address){
        bytes memory constructorData = abi.encode(config.eraChainId);


        address implAddr = calcualateAddress({
            sender: config.sender,
            bytecode: contracts.l2SharedBridgeBytecode,
            constructorargs: constructorData,
            create2salt: ""

        });
        return implAddr;
    }

    function proxyAdminAddr() internal returns (address){
        bytes[] memory factoryDeps = new bytes[](0);

        address proxyAdminContract = calcualateAddress({
            sender: config.sender,
            bytecode: contracts.proxyAdminBytecode,
            constructorargs: "",
            create2salt: ""
        });
        return proxyAdminContract;
    }

    function sharedBridgeProxyAddr(address implAddr, address proxyadmin) internal {
        address l2GovernorAddress = proxyadmin;
        bytes32 l2StandardErc20BytecodeHash = L2ContractHelper.hashL2Bytecode(contracts.beaconProxy);

        string memory functionSignature;

        functionSignature = "initialize(address,address,bytes32,address)";
        // solhint-disable-next-line func-named-parameters
        bytes memory proxyInitializationParams = abi.encodeWithSignature(
            functionSignature,
            config.l1SharedBridgeProxy,
            config.erc20BridgeProxy,
            l2StandardErc20BytecodeHash,
            l2GovernorAddress
        );

        bytes memory l2SharedBridgeProxyConstructorData = abi.encode(
            implAddr,
            l2GovernorAddress,
            proxyInitializationParams
        );

        address l2SharedBridgeProxy = calcualateAddress({
            sender: config.sender,
            bytecode: contracts.l2SharedBridgeProxyBytecode,
            constructorargs: l2SharedBridgeProxyConstructorData,
            create2salt: ""
        });

        console.log("Final address");
        console.logAddress(l2SharedBridgeProxy);
    }
}
