// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {L2SharedBridgeTestWrapper} from "./_L2SharedBridge_Shared.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IL2SharedBridge} from "solpp/bridge/interfaces/IL2SharedBridge.sol";
import {L2SharedBridge} from "solpp/bridge/L2SharedBridge.sol";
import {IL2StandardToken} from "solpp/bridge/interfaces/IL2StandardToken.sol";
import {AddressAliasHelper} from "solpp/vendor/AddressAliasHelper.sol";
import {ERA_CHAIN_ID} from "solpp/Config.sol";

contract L2SharedBridgeTest is Test {
    L2SharedBridgeTestWrapper bridge;
    address l1Bridge;
    address l1LegacyBridge;

    function setUp() public {
        l1Bridge = makeAddr("l1Bridge");
        l1LegacyBridge = makeAddr("l1LegecyBridge");
        address aliasedOwner = makeAddr("aliasedOwner");

        bytes32 bytecodeHash = "0x123456";
        L2SharedBridgeTestWrapper bridgeImpl = new L2SharedBridgeTestWrapper();
        vm.chainId(ERA_CHAIN_ID);
        ERC1967Proxy proxy = new ERC1967Proxy(address(bridgeImpl), "");
        bridge = L2SharedBridgeTestWrapper(address(proxy));
        bridge.initialize(l1Bridge, l1LegacyBridge, bytecodeHash, aliasedOwner);
    }

    function test_finalizeDepositSuccessWithoutDeployment() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");
        address l1Token = makeAddr("l1Token");
        uint256 amount = 123;
        address expectedL2Addr = bridge.l2TokenAddress(l1Token);

        bridge.setTokenAddress(expectedL2Addr, l1Token);
        vm.mockCall(expectedL2Addr, abi.encodeWithSelector(IL2StandardToken.bridgeMint.selector), abi.encode(receiver, amount));
        // TODO: expect event to be emitted
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Bridge));
        bridge.finalizeDeposit(sender, receiver, l1Token, amount, new bytes(0));
    }
}
