// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {Script, console2 as console} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";

import {L2StandardERC20} from "contracts/bridge/L2StandardERC20.sol";
import {L2AssetRouter}  from "contracts/bridge/L2AssetRouter.sol";

import { UpgradeableBeacon } from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import { BeaconProxy } from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import { IContractDeployer, DEPLOYER_SYSTEM_CONTRACT, L2ContractHelper, L2_ASSET_ROUTER, L2_NATIVE_TOKEN_VAULT } from "contracts/L2ContractHelper.sol";

import {L2NativeTokenVault} from "contracts/bridge/L2NativeTokenVault.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {Utils } from "../utils/Utils.sol";

contract L1Erc20BridgeTest is Test {
    // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
    // It is a bit easier to use EOA and it is sufficient for the tests.
    address l1BridgeWallet = address(1);
    address aliasedL1BridgeWallet;

    // The owner of the beacon and the native token vault
    address ownerWallet = address(2);

    L2StandardERC20 standardErc20Impl;

    UpgradeableBeacon beacon;

    uint256 constant L1_CHAIN_ID = 9;
    uint256 ERA_CHAIN_ID = 270;

    // We won't actually deploy an L1 token in these tests, but we need some address for it.
    address L1_TOKEN_ADDRESS = 0x1111100000000000000000000000000000011111;

    string constant TOKEN_DEFAULT_NAME = "TestnetERC20Token";
    string constant TOKEN_DEFAULT_SYMBOL = "TET";
    uint8 constant TOKEN_DEFAULT_DECIMALS = 18;


    function setUp() public {
        aliasedL1BridgeWallet = AddressAliasHelper.applyL1ToL2Alias(l1BridgeWallet);

        standardErc20Impl = new L2StandardERC20();

        beacon = new UpgradeableBeacon(address(standardErc20Impl));
        beacon.transferOwnership(ownerWallet);

        // One of the purposes of deploying it here is to publish its bytecode
        BeaconProxy proxy = new BeaconProxy(address(beacon), new bytes(0));

        bytes32 beaconProxyBytecodeHash;
        assembly {
            beaconProxyBytecodeHash := extcodehash(proxy)
        }
    
        Utils.initSystemContracts();
        Utils.forceDeployAssetRouter(
            L1_CHAIN_ID, 
            ERA_CHAIN_ID, 
            l1BridgeWallet, 
            address(0)
        );
        Utils.forceDeployNativeTokenVault(
            L1_CHAIN_ID,
            ownerWallet,
            beaconProxyBytecodeHash,
            address(0),
            address(beacon),
            true
        );
    }

    function performDeposit(
        address depositor,
        address receiver,
        uint256 amount
    ) internal {
        vm.prank(aliasedL1BridgeWallet);
        L2AssetRouter(address(L2_ASSET_ROUTER)).finalizeDeposit(
            depositor,
            receiver,
            L1_TOKEN_ADDRESS,
            amount,
            Utils.encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        );
    }

    function initializeTokenByDeposit() internal returns (address l2TokenAddress) {
        performDeposit(
            makeAddr("someDepositor"),
            makeAddr("someReeiver"),
            1
        );

        l2TokenAddress = L2_NATIVE_TOKEN_VAULT.l2TokenAddress(L1_TOKEN_ADDRESS);
        require(l2TokenAddress != address(0), "Token not initialized");
    }

    function test_shouldFinalizeERC20Deposit() public {
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");

        performDeposit(
            depositor,
            receiver,
            100
        );

        address l2TokenAddress = L2_NATIVE_TOKEN_VAULT.l2TokenAddress(L1_TOKEN_ADDRESS);

        assertEq(L2StandardERC20(l2TokenAddress).balanceOf(receiver), 100);
        assertEq(L2StandardERC20(l2TokenAddress).totalSupply(), 100);
        assertEq(L2StandardERC20(l2TokenAddress).name(), TOKEN_DEFAULT_NAME);
        assertEq(L2StandardERC20(l2TokenAddress).symbol(), TOKEN_DEFAULT_SYMBOL);
        assertEq(L2StandardERC20(l2TokenAddress).decimals(), TOKEN_DEFAULT_DECIMALS);
    }

    function test_governanceShouldBeAbleToReinitializeToken() public {
        address l2TokenAddress = initializeTokenByDeposit();

        L2StandardERC20.ERC20Getters memory getters =  L2StandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        vm.prank(ownerWallet);
        L2StandardERC20(l2TokenAddress).reinitializeToken(
            getters,
            "TestTokenNewName",
            "TTN",
            2
        );
        assertEq(L2StandardERC20(l2TokenAddress).name(), "TestTokenNewName");
        assertEq(L2StandardERC20(l2TokenAddress).symbol(), "TTN");
        // The decimals should stay the same
        assertEq(L2StandardERC20(l2TokenAddress).decimals(), 18);
    }

    function test_governanceShoudNotBeAbleToSkipInitializerVersions() public {
        address l2TokenAddress = initializeTokenByDeposit();
        
        L2StandardERC20.ERC20Getters memory getters =  L2StandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        vm.expectRevert();
        vm.prank(ownerWallet);
        L2StandardERC20(l2TokenAddress).reinitializeToken(
            getters,
            "TestTokenNewName",
            "TTN",
            20
        );
    }
}
