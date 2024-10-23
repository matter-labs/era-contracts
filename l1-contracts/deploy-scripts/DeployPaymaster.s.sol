// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {console2 as console} from "forge-std/Script.sol";
import {Utils} from "./Utils.sol";

contract DeployPaymaster is Script {
    using stdToml for string;
    Config internal config;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        uint256 chainId;
        address paymaster;
    }

    function getPaymasterAddress() public view returns (address) {
        return config.paymaster;
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deploy-script-config-template/config-deploy-paymaster.toml");
        string memory toml = vm.readFile(path);
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");

        path = string.concat(root, "/script-out/output-deploy-l1.toml");
        toml = vm.readFile(path);
        config.bridgehubAddress = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.chainId = toml.readUint("$.era_chain_id");
    }

    function saveOutput() internal {
        string memory toml = vm.serializeAddress("root", "paymaster", config.paymaster);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-paymaster.toml");
        vm.writeToml(toml, path);
    }

    function run() external {
        initializeConfig();

        deploy();

        saveOutput();
    }

    function deploy() internal {
        bytes memory testnetPaymasterBytecode = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/TestnetPaymaster.sol/TestnetPaymaster.json"
        );
        config.paymaster = Utils.deployThroughL1({
            bytecode: testnetPaymasterBytecode,
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy,
            chainId: config.chainId
        });
    }
}
