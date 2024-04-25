// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {L2WrappedBaseToken} from "../contracts/bridge/L2WrappedBaseToken.sol";
import {L2SharedBridge} from "../contracts/bridge/L2SharedBridge.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

address constant richAccount = 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049;
address constant randomAddress = 0xEb1E345A7eAD1F524F5af5b0B9540B98f62fE844;
uint256 constant testChainId = 9;

contract WethTest is Test {
    address constant wallet = richAccount;
    L2WrappedBaseToken wethToken;
    L2SharedBridge wethBridge;
    function setUp() public {
        /*vm.prank(wallet);
        L2WrappedBaseToken wethTokenImpl = new L2WrappedBaseToken();
        L2SharedBridge wethBridgeImpl  = new L2SharedBridge(testChainId);
        TransparentUpgradeableProxy wethTokenProxy = TransparentUpgradeableProxy(address(wethBridgeImpl),randomAddress,"");
        TransparentUpgradeableProxy wethBridgeProxy = TransparentUpgradeableProxy(wethBridgeImpl.address,randomAddress,"");
        wethToken = L2WrappedBaseToken(address(wethTokenProxy));
        wethBridge = L2SharedBridge(address(wethBridgeProxy));
        wethToken.initializeV2("Wrapped Ether", "WETH", address(wethBridge), randomAddress);*/
    }
    function test_WethDeposit() public{
        //wethToken.deposit(18);
    }
}