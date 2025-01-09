// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_MESSENGER} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "./_SharedL2ContractDeployer.sol";

abstract contract L2Erc20TestAbstract is Test, SharedL2ContractDeployer {
    function performDeposit(address depositor, address receiver, uint256 amount) internal {
        vm.prank(aliasedL1AssetRouter);
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit({
            _l1Sender: depositor,
            _l2Receiver: receiver,
            _l1Token: L1_TOKEN_ADDRESS,
            _amount: amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });
    }

    function initializeTokenByDeposit() internal returns (address l2TokenAddress) {
        performDeposit(makeAddr("someDepositor"), makeAddr("someReeiver"), 1);

        l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);
        if (l2TokenAddress == address(0)) {
            revert("Token not initialized");
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

    function test_governanceShouldNotBeAbleToSkipInitializerVersions() public {
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

    function test_withdrawTokenNoRegistration() public {
        TestnetERC20Token l2NativeToken = new TestnetERC20Token("token", "T", 18);

        l2NativeToken.mint(address(this), 100);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, 100);

        // Basically we want all L2->L1 transactions to pass
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)"),
            abi.encode(bytes32(uint256(1)))
        );

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(l2NativeToken));

        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(
            assetId,
            DataEncoding.encodeBridgeBurnData(100, address(1), address(l2NativeToken))
        );
    }

    function test_calldataWith() public {
        bytes
            memory data = hex"d52471c1000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001f9000000000000000000000000000000000000000000000001158e460913d000000000000000000000000000009ca26d77cde9cff9145d06725b400b2ec4bbc6160000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000023c34600000000000000000000000000000000000000000000000000000000000000032000000000000000000000000000000000000000000000000000000000000001400000000000000000000000009ca26d77cde9cff9145d06725b400b2ec4bbc61600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        // bytes
        //     memory data = hex"9c884fd100000000000000000000000000000000000000000000000000000000000001109c0d4add1b94fd348199e854b0efbc68c1ec865016908282cfa32b5c02a69606000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000001a36f9dbffc50cd7c7d5ccec1ce3232d1f08280b0000000000000000000000008da7cffaf1eab3bce2817d0c20ef5cd7ce82455a00000000000000000000000060d16f709e9179f961d5786f8d035e337990971f0000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c1010000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004574254430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000";
        // // bytes memory data = hex"9c884fd100000000000000000000000000000000000000000000000000000000000001109c0d4add1b94fd348199e854b0efbc68c1ec865016908282cfa32b5c02a69606000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000001a36f9dbffc50cd7c7d5ccec1ce3232d1f08280b0000000000000000000000008da7cffaf1eab3bce2817d0c20ef5cd7ce82455a00000000000000000000000060d16f709e9179f961d5786f8d035e337990971f0000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000045742544300000000000000000000000000000000000000000000000000000000";
        // console.logBytes(data);
        // bytes memory data2 = abi.encodeCall(
        //     IAssetRouterBase.finalizeDeposit,
        //     (272, bytes32(uint256(2)), abi.encode(address(1), address(0), address(0), 0, ""))
        // );
        // console.logBytes(data2);
        // uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();
        // console.log("l1ChainId", l1ChainId);
        // address recipient = 0x0000000000000000000000000000000000010003;
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(
            address(L2_MESSENGER),
            abi.encodeWithSelector(L2_MESSENGER.sendToL1.selector),
            abi.encode(bytes32(0))
        );
        address recipient = L2_BRIDGEHUB_ADDR;
        (bool success, ) = recipient.call(data);
        assertTrue(success);
    }
}
