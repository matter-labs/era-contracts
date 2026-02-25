// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

abstract contract L2Erc20TestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

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

        uint256 mintAmount = 100;
        l2NativeToken.mint(address(this), mintAmount);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, mintAmount);

        // Verify initial balance
        assertEq(l2NativeToken.balanceOf(address(this)), mintAmount, "Initial balance should be minted amount");

        // Basically we want all L2->L1 transactions to pass
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSignature("sendToL1(bytes)"),
            abi.encode(bytes32(uint256(1)))
        );

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(l2NativeToken));

        // Verify asset ID is properly constructed
        assertTrue(assetId != bytes32(0), "Asset ID should be non-zero");

        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(
            assetId,
            DataEncoding.encodeBridgeBurnData(mintAmount, address(1), address(l2NativeToken))
        );

        // After withdrawal, tokens should be burned from the sender
        assertEq(l2NativeToken.balanceOf(address(this)), 0, "Balance should be zero after withdrawal");
    }
}
