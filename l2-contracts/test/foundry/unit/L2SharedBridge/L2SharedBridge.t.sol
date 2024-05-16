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
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {L2StandardERC20} from "solpp/bridge/L2StandardERC20.sol";

contract L2SharedBridgeTest is Test {
    L2SharedBridgeTestWrapper bridge;
    address l1Bridge;
    address l1LegacyBridge;
    address aliasedOwner;

    function setUp() public {
        l1Bridge = makeAddr("l1Bridge");
        l1LegacyBridge = makeAddr("l1LegecyBridge");
        aliasedOwner = makeAddr("aliasedOwner");

        // Deploy a token or proxy contract for hashing
        L2StandardERC20 tokenImpl = new L2StandardERC20();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl));
        vm.label(address(beacon), "UpgradeableBeacon for L2StandardERC20");
        // Used for initialize fn of L2SharedBridge for hash of proxy bytecode
        bytes memory beaconBytecode = abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(address(tokenImpl)));
        bytes32 beaconProxyBytecodeHash = keccak256(beaconBytecode);

        vm.chainId(ERA_CHAIN_ID);

        // Deploy L2SharedBridge implementation
        L2SharedBridgeTestWrapper bridgeImpl = new L2SharedBridgeTestWrapper();
        vm.label(address(bridgeImpl), "L2SharedBridge Implementation");

        // Deploy an ERC1967Proxy using the bridge implementation
        bytes memory initData = abi.encodeWithSelector(
            L2SharedBridge.initialize.selector,
            l1Bridge,
            address(0),
            beaconProxyBytecodeHash,
            aliasedOwner
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bridgeImpl),
            initData
        );

        // Cast the proxy address to the L2SharedBridge to interact with it
        bridge = L2SharedBridgeTestWrapper(address(proxy));
    }

    function test_finalizeDepositSuccessWithoutDeployment() public {
        console.log("test_finalizeDepositSuccessWithoutDeployment");

        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");
        address l1Token = makeAddr("l1Token");
        emit log_address(l1Token);
        uint256 amount = 123;
        address expectedL2Addr = bridge.l2TokenAddress(l1Token);

        bridge.setTokenAddress(expectedL2Addr, l1Token);
        vm.mockCall(expectedL2Addr, abi.encodeWithSelector(IL2StandardToken.bridgeMint.selector), abi.encode(receiver, amount));
        // TODO: expect event to be emitted
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Bridge));

        bridge.finalizeDeposit(sender, receiver, l1Token, amount, new bytes(0));
    }
}