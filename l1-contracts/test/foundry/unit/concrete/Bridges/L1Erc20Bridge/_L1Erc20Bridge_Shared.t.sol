// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {FeeOnTransferToken} from "contracts/dev-contracts/FeeOnTransferToken.sol";
import {ReenterL1ERC20Bridge} from "contracts/dev-contracts/test/ReenterL1ERC20Bridge.sol";
import {Utils} from "../../Utils/Utils.sol";

contract L1Erc20BridgeTest is Test {
    L1ERC20Bridge internal bridge;

    ReenterL1ERC20Bridge internal reenterL1ERC20Bridge;
    L1ERC20Bridge internal bridgeReenterItself;

    TestnetERC20Token internal token;
    TestnetERC20Token internal feeOnTransferToken;
    address internal randomSigner;
    address internal alice;
    address sharedBridgeAddress;

    constructor() {
        randomSigner = makeAddr("randomSigner");
        alice = makeAddr("alice");

        sharedBridgeAddress = makeAddr("shared bridge");
        bridge = new L1ERC20Bridge(IL1SharedBridge(sharedBridgeAddress));

        reenterL1ERC20Bridge = new ReenterL1ERC20Bridge();
        bridgeReenterItself = new L1ERC20Bridge(IL1SharedBridge(address(reenterL1ERC20Bridge)));
        reenterL1ERC20Bridge.setBridge(bridgeReenterItself);

        token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        feeOnTransferToken = new FeeOnTransferToken("FeeOnTransferToken", "FOT", 18);
        token.mint(alice, type(uint256).max);
        feeOnTransferToken.mint(alice, type(uint256).max);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
