// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployPaymaster} from "../../../deploy-scripts/DeployPaymaster.s.sol";

contract DeployPaymasterTest is Test {
    using stdToml for string;

    struct Config {
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        uint256 chainId;
        address paymaster;
    }

    Config config;

    DeployPaymaster private deployScript;

    function setUp() public {
        string memory url = getChain(1).rpcUrl;
        vm.createSelectFork({urlOrAlias: url, blockNumber: 16_428_900});
        vm.allowCheatcodes(0xEA785A9c91A07ED69b83EB165f4Ce2C30ecb4c0b);
        vm.deal(0xEA785A9c91A07ED69b83EB165f4Ce2C30ecb4c0b, 720000000000000);
        vm.allowCheatcodes(0x51dE418cB7f5b630D5Ca9A49514e34E2420a66b3);
        deployScript  = new DeployPaymaster();
        deployScript.run();

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-paymaster.toml");
        string memory toml = vm.readFile(path);
        config.paymaster = toml.readAddress("$.paymaster");
    }

    function test() public {
        address paymasterAddress = deployScript.getPaymasterAddress();
        address paymasterAddressCheck = config.paymaster;
        assertEq(paymasterAddress, paymasterAddressCheck);
    }
}