// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployPaymaster} from "../../../deploy-scripts/DeployPaymaster.s.sol";
import {RegisterHyperchainScript} from "../../../deploy-scripts/RegisterHyperchain.s.sol";
import {DeployL1Script} from "../../../deploy-scripts/DeployL1.s.sol";
import {_DeployL1Script} from "../../../deploy-scripts/_DeployL1.s.sol";
import {Bridgehub} from "../../../contracts/bridgehub/Bridgehub.sol";

contract DeployPaymasterTest is Test {
    using stdToml for string;

    struct Config {
        address bridgehubAddress;
        address l1SharedBridgeProxy;
        uint256 chainId;
        address paymaster;
    }

    Config config;
    address bridgehubProxyAddress;
    Bridgehub bridgeHub;

    DeployPaymaster private deployPaymaster;
    DeployL1Script private deployL1;
    _DeployL1Script private _deployL1;
    RegisterHyperchainScript private deployHyperchain;

    function _acceptOwnership() private {
            vm.startPrank(bridgeHub.pendingOwner());
            bridgeHub.acceptOwnership();
            vm.stopPrank();
        }

    function setUp() public {
        deployL1 = new DeployL1Script();
        deployL1.run();
        
        _deployL1 = new _DeployL1Script();
        _deployL1._run();
        
        bridgehubProxyAddress = _deployL1._getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);
        _acceptOwnership();

        vm.warp(100);
        deployHyperchain = new RegisterHyperchainScript();
        deployHyperchain.run();

        string memory url = getChain(1).rpcUrl;
        vm.createSelectFork({urlOrAlias: url, blockNumber: 16_428_900});
        vm.deal(0xEA785A9c91A07ED69b83EB165f4Ce2C30ecb4c0b, 720000000000000);
        deployPaymaster  = new DeployPaymaster();
        deployPaymaster.run();

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-paymaster.toml");
        string memory toml = vm.readFile(path);
        config.paymaster = toml.readAddress("$.paymaster");
    }

    function test_checkPaymasterAddress() public {
        address paymasterAddress = deployPaymaster.getPaymasterAddress();
        address paymasterAddressCheck = config.paymaster;
        assertEq(paymasterAddress, paymasterAddressCheck);
    }
}