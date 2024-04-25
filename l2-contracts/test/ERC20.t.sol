// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {L2SharedBridge} from "l2-contracts/bridge/L2SharedBridge.sol";
import {L2StandardERC20} from "l2-contracts/bridge/L2StandardERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

address constant deployerWallet = address(0x36615Cf349d7F6344891B1e7CA7C72883F5dc049);
address constant governorWallet = address(0xa61464658AfeAf65CccaaFD3a512b69A83B77618);

// We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
// It is a bit easier to use EOA and it is sufficient for the tests.
address constant l1BridgeWallet = address(0x0D43eB5B8a47bA8900d84AA36656c92024e9772e);

uint256 constant testChainId = 9;

uint256 constant L1_TO_L2_ALIAS_OFFSET = uint256(uint160(0x1111000000000000000000000000000000001111));
uint256 constant ADDRESS_MODULO = 2 ** 160;

address constant L1_TOKEN_ADDRESS = 0x1111000000000000000000000000000000001111;

contract ERC20Test is Test {
    L2SharedBridge private erc20Bridge;
    L2StandardERC20 private erc20Token;

    function unapplyL1ToL2Alias(address addr) public pure returns (address) {
        uint256 addressNum = uint256(uint160(addr));
        // Perform the offset subtraction and modulo operation
        if (addressNum < L1_TO_L2_ALIAS_OFFSET) {
            addressNum = addressNum + ADDRESS_MODULO - L1_TO_L2_ALIAS_OFFSET;
        } else {
            addressNum = addressNum - L1_TO_L2_ALIAS_OFFSET;
        }
        addressNum = addressNum % ADDRESS_MODULO;
        return address(uint160(addressNum));
    }

    function setUp() public {
        vm.prank(deployerWallet);

        address l2TokenImplAddress = address(new L2StandardERC20());
        address l2Erc20TokenBeacon = address(new UpgradeableBeacon(l2TokenImplAddress));
        address beaconProxyAddress = address(new BeaconProxy(l2Erc20TokenBeacon, ""));

        bytes memory beaconProxyBytecodeHash = beaconProxyAddress.code;

        address erc20BridgeImpl = address(new L2SharedBridge(testChainId));
        bytes memory bridgeInitializeData = abi.encodeWithSelector(
            L2SharedBridge(erc20BridgeImpl).initialize.selector,
            unapplyL1ToL2Alias(l1BridgeWallet),
            address(0),
            beaconProxyBytecodeHash,
            governorWallet
        );

        TransparentUpgradeableProxy erc20BridgeProxy = new TransparentUpgradeableProxy(
            erc20BridgeImpl,
            governorWallet,
            bridgeInitializeData
        );
        erc20Bridge = L2SharedBridge(address(erc20BridgeProxy));
    }

    function test_FinalizeERC20Deposit() public {
        vm.prank(l1BridgeWallet);

        L2SharedBridge erc20BridgeWithL1Bridge = erc20Bridge;

        address l1Depositor = makeAddr(vm.toString(uint256(1)));
        address l2Receiver = makeAddr(vm.toString(uint256(2)));

        vm.expectEmit(true, true, true, true);
        vm.prank(l1Depositor);

        address l2TokenAddress = erc20BridgeWithL1Bridge.finalizeDeposit(
            l1Depositor,
            l2Receiver,
            L1_TOKEN_ADDRESS,
            100,
            abi.encode("TestToken", "TT", 18)
        );

        erc20Token = L2StandardERC20(l2TokenAddress);
        assert(erc20Token.balanceOf(l2Receiver) == 100);
        assert(erc20Token.totalSupply() == 100);
        assert(keccak256(abi.encodePacked(erc20Token.name())) == keccak256(abi.encodePacked("TestToken")));
        assert(keccak256(abi.encodePacked(erc20Token.symbol())) == keccak256(abi.encodePacked("TT")));
        assert(erc20Token.decimals() == 18);
    }

    function test_GovernanceTokenReinit() public {
        vm.prank(governorWallet);

        L2StandardERC20 erc20TokenWithGovernor = erc20Token;
        erc20TokenWithGovernor.reinitializeToken(
            L2StandardERC20.ERC20Getters(false, false, false),
            "TestTokenNewName",
            "TTN",
            2
        );

        assert(keccak256(abi.encodePacked(erc20Token.name())) == keccak256(abi.encodePacked("TestToken")));
        assert(keccak256(abi.encodePacked(erc20Token.symbol())) == keccak256(abi.encodePacked("TTN")));
        assert(erc20Token.decimals() == 18);
    }

    function testFail_GovernanceSkipInitializer() public {
        vm.prank(governorWallet);

        L2StandardERC20 erc20TokenWithGovernor = erc20Token;
        erc20TokenWithGovernor.reinitializeToken(
            L2StandardERC20.ERC20Getters(false, false, false),
            "TestTokenNewName",
            "TTN",
            20
        );
    }
}
