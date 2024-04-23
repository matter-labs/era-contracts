// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {L2ERC20BridgeTestWrapper} from "./_L2ERC20Bridge.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {L2ERC20Bridge} from "contracts/bridge/L2ERC20Bridge.sol";
import {L2StandardERC20} from "contracts/bridge/L2StandardERC20.sol";
import {AddressAliasHelper} from "../../../contracts/vendor/AddressAliasHelper.sol";
import {IL2StandardToken} from "contracts/bridge/interfaces/IL2StandardToken.sol";

contract L2ERC20BridgeTest is Test {
    L2ERC20BridgeTestWrapper bridge;
    UpgradeableBeacon beacon;
    address l1BridgeMock;
    address governorMock;
    bytes32 l2TokenProxyBytecodeHash;
    event FinalizeDeposit(
        address indexed l1Sender,
        address indexed l2Receiver,
        address indexed l2Token,
        uint256 amount
    );

    function setUp() public {
        l1BridgeMock = makeAddr("l1Bridge");
        governorMock = makeAddr("governor");

        L2StandardERC20 tokenImpl = new L2StandardERC20();
        beacon = new UpgradeableBeacon(address(tokenImpl));
        vm.label(address(beacon), "UpgradeableBeacon for L2StandardERC20");
        console.log("Beacon address: %s", address(beacon));
        // Compute bytecode hash for the BeaconProxy
        bytes memory beaconProxyBytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon)));
        l2TokenProxyBytecodeHash = keccak256(beaconProxyBytecode);

        L2ERC20BridgeTestWrapper bridgeImpl = new L2ERC20BridgeTestWrapper();
        vm.label(address(bridgeImpl), "L2ERC20Bridge Implementation");
        console.log("L2ERC20Bridge address: %s", address(bridgeImpl));
        
        bytes memory initData = abi.encodeWithSelector(
            L2ERC20Bridge.initialize.selector,
            l1BridgeMock,
            l2TokenProxyBytecodeHash,
            governorMock
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bridgeImpl),
            initData
        );
        console.log("BeaconProxy address: %s", address(proxy));
        bridge = L2ERC20BridgeTestWrapper(address(proxy));
    }

    function test_FinalizeDeposit() public {
        console.log("Running test_FinalizeDeposit");
    
        address l1Sender = makeAddr("l1Sender");
        address l2Receiver = makeAddr("l2Receiver");
        address l1Token = makeAddr("l1Token");
        uint256 amount = 1000;
        bytes memory data = new bytes(0);
    
        // Create a mock L2 token and register it in the bridge
        L2StandardERC20 mockL2Token = new L2StandardERC20();
        vm.label(address(mockL2Token), "MockL2Token");
        bridge.setTokenAddress(address(mockL2Token), l1Token);
    
        address expectedL2Token = bridge.l2TokenAddress(l1Token);
        bridge.setTokenAddress(expectedL2Token, l1Token); 
        vm.mockCall(expectedL2Token, abi.encodeWithSelector(IL2StandardToken(expectedL2Token).bridgeMint.selector), abi.encode(true));
    
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1BridgeMock));
    
        vm.expectEmit(true, true, true, true);
        emit FinalizeDeposit(l1Sender, l2Receiver, expectedL2Token, amount);
    
        bridge.finalizeDeposit(l1Sender, l2Receiver, l1Token, amount, data);
    
        assertEq(bridge.l1TokenAddress(expectedL2Token), l1Token, "L1 token mapping should match");
    }
}
