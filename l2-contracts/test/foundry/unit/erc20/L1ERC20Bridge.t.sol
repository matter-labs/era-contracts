// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2StandardERC20} from "contracts/bridge/L2StandardERC20.sol";

contract L1Erc20BridgeTest is Test {
    // L1ERC20Bridge internal bridge;

    // ReenterL1ERC20Bridge internal reenterL1ERC20Bridge;
    // L1ERC20Bridge internal bridgeReenterItself;

    // TestnetERC20Token internal token;
    // TestnetERC20Token internal feeOnTransferToken;
    // address internal randomSigner;
    // address internal alice;
    // address sharedBridgeAddress;

    constructor() {
        // randomSigner = makeAddr("randomSigner");
        // alice = makeAddr("alice");

        // sharedBridgeAddress = makeAddr("shared bridge");
        // bridge = new L1ERC20Bridge(IL1SharedBridge(sharedBridgeAddress));

        // reenterL1ERC20Bridge = new ReenterL1ERC20Bridge();
        // bridgeReenterItself = new L1ERC20Bridge(IL1SharedBridge(address(reenterL1ERC20Bridge)));
        // reenterL1ERC20Bridge.setBridge(bridgeReenterItself);

        // token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        // feeOnTransferToken = new FeeOnTransferToken("FeeOnTransferToken", "FOT", 18);
        // token.mint(alice, type(uint256).max);
        // feeOnTransferToken.mint(alice, type(uint256).max);
    }

    // add this to be excluded from coverage report
    // function test() internal virtual {}

    function test_Stuff() public {
        L2StandardERC20 l2StandardERC20 = new L2StandardERC20();
    }
}
