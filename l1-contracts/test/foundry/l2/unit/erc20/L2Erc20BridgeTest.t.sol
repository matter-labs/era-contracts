// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {TokenNotInitialized} from "test/foundry/L1TestsErrors.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {L2Utils} from "../utils/L2Utils.sol";

contract L2Erc20BridgeTest is Test {
    // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
    // It is a bit easier to use EOA and it is sufficient for the tests.
    address internal l1BridgeWallet = address(1);
    address internal aliasedL1BridgeWallet;

    // The owner of the beacon and the native token vault
    address internal ownerWallet = address(2);

    BridgedStandardERC20 internal standardErc20Impl;

    UpgradeableBeacon internal beacon;
    BeaconProxy internal proxy;

    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal ERA_CHAIN_ID = 270;

    // We won't actually deploy an L1 token in these tests, but we need some address for it.
    address internal L1_TOKEN_ADDRESS = 0x1111100000000000000000000000000000011111;

    string internal constant TOKEN_DEFAULT_NAME = "TestnetERC20Token";
    string internal constant TOKEN_DEFAULT_SYMBOL = "TET";
    uint8 internal constant TOKEN_DEFAULT_DECIMALS = 18;

    function setUp() public {
        aliasedL1BridgeWallet = AddressAliasHelper.applyL1ToL2Alias(l1BridgeWallet);

        standardErc20Impl = new BridgedStandardERC20();
        beacon = new UpgradeableBeacon(address(standardErc20Impl));
        beacon.transferOwnership(ownerWallet);

        // One of the purposes of deploying it here is to publish its bytecode
        BeaconProxy beaconProxy = new BeaconProxy(address(beacon), new bytes(0));
        proxy = beaconProxy;
        bytes32 beaconProxyBytecodeHash;
        assembly {
            beaconProxyBytecodeHash := extcodehash(beaconProxy)
        }

        L2Utils.initSystemContracts();
        L2Utils.forceDeployAssetRouter(L1_CHAIN_ID, ERA_CHAIN_ID, ownerWallet, l1BridgeWallet, address(0));
        L2Utils.forceDeployNativeTokenVault({
            _l1ChainId: L1_CHAIN_ID,
            _aliasedOwner: ownerWallet,
            _l2TokenProxyBytecodeHash: beaconProxyBytecodeHash,
            _legacySharedBridge: address(0),
            _l2TokenBeacon: address(beacon),
            _contractsDeployedAlready: true
        });
    }

    function performDeposit(address depositor, address receiver, uint256 amount) internal {
        vm.prank(aliasedL1BridgeWallet);
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit({
            _l1Sender: depositor,
            _l2Receiver: receiver,
            _l1Token: L1_TOKEN_ADDRESS,
            _amount: amount,
            _data: L2Utils.encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });
    }

    function initializeTokenByDeposit() internal returns (address l2TokenAddress) {
        performDeposit(makeAddr("someDepositor"), makeAddr("someReeiver"), 1);

        l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);
        if (l2TokenAddress == address(0)) {
            revert TokenNotInitialized();
        }
    }

    function test_shouldFinalizeERC20Deposit() public {
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");

        performDeposit(depositor, receiver, 100);

        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        assertEq(BridgedStandardERC20(l2TokenAddress).balanceOf(receiver), 100);
        assertEq(BridgedStandardERC20(l2TokenAddress).totalSupply(), 100);
        assertEq(BridgedStandardERC20(l2TokenAddress).name(), TOKEN_DEFAULT_NAME);
        assertEq(BridgedStandardERC20(l2TokenAddress).symbol(), TOKEN_DEFAULT_SYMBOL);
        assertEq(BridgedStandardERC20(l2TokenAddress).decimals(), TOKEN_DEFAULT_DECIMALS);
    }

    function test_governanceShouldBeAbleToReinitializeToken() public {
        address l2TokenAddress = initializeTokenByDeposit();

        BridgedStandardERC20.ERC20Getters memory getters = BridgedStandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        vm.prank(ownerWallet);
        BridgedStandardERC20(l2TokenAddress).reinitializeToken(getters, "TestTokenNewName", "TTN", 2);
        assertEq(BridgedStandardERC20(l2TokenAddress).name(), "TestTokenNewName");
        assertEq(BridgedStandardERC20(l2TokenAddress).symbol(), "TTN");
        // The decimals should stay the same
        assertEq(BridgedStandardERC20(l2TokenAddress).decimals(), 18);
    }

    function test_governanceShouldlNotBeAbleToSkipInitializerVersions() public {
        address l2TokenAddress = initializeTokenByDeposit();

        BridgedStandardERC20.ERC20Getters memory getters = BridgedStandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        vm.expectRevert();
        vm.prank(ownerWallet);
        BridgedStandardERC20(l2TokenAddress).reinitializeToken(getters, "TestTokenNewName", "TTN", 20);
    }
}
