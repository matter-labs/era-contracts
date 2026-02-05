// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "../utils/Utils.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IDeployPaymaster} from "contracts/script-interfaces/IDeployPaymaster.sol";

contract DeployPaymaster is Script, IDeployPaymaster {
    using stdToml for string;
    Config internal config;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        uint256 chainId;
        address paymaster;
    }

    function initializeConfig(address bridgehubAddress, uint256 chainId) internal {
        config.bridgehubAddress = bridgehubAddress;
        config.chainId = chainId;

        // Get the assetRouter address directly from bridgehub for deposit approvals
        config.l1SharedBridgeProxy = address(IL1Bridgehub(bridgehubAddress).assetRouter());
    }

    function saveOutput() internal {
        string memory toml = vm.serializeAddress("root", "paymaster", config.paymaster);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-paymaster.toml");
        vm.writeToml(toml, path);
    }

    function run(address _bridgehub, uint256 _chainId) external {
        initializeConfig(_bridgehub, _chainId);

        deploy();

        saveOutput();
    }

    function deploy() internal {
        bytes memory testnetPaymasterBytecode = Utils.readZKFoundryBytecodeL2(
            "TestnetPaymaster.sol",
            "TestnetPaymaster"
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
