// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {Unauthorized, BridgeMintNotImplemented} from "contracts/common/L1ContractErrors.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./Utils.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

abstract contract L2WethTestAbstract is Test, SharedL2ContractDeployer {
    function test_shouldDepositWethByCallingDeposit() public {
        uint256 amount = 100;
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(address(this)), amount);
    }

    function test_shouldDepositWethBySendingEth() public {
        uint256 amount = 100;
        address(weth).call{value: amount}("");
        assertEq(weth.balanceOf(address(this)), amount);
    }

    function test_revertWhenDepositingWithRandomCalldata() public {
        (bool success, ) = address(weth).call{value: 100}(hex"00000000");
        assertEq(success, false);
    }

    function test_shouldWithdrawWethToL2Eth() public {
        address sender = makeAddr("sender");
        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.deposit{value: amount}();

        vm.prank(sender);
        weth.withdraw(amount);

        assertEq(weth.balanceOf(sender), 0);
        assertEq(address(sender).balance, amount);
    }

    function test_shouldDepositWethToAnotherAccount() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");

        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.depositTo{value: amount}(receiver);

        assertEq(weth.balanceOf(receiver), amount);
        assertEq(weth.balanceOf(sender), 0);
    }

    function test_shouldWithdrawWethToAnotherAccount() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");

        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.deposit{value: amount}();

        vm.prank(sender);
        weth.withdrawTo(receiver, amount);

        assertEq(receiver.balance, amount);
        assertEq(sender.balance, 0);
    }

    function test_revertWhenWithdrawingMoreThanBalance() public {
        vm.expectRevert();
        weth.withdraw(1);
    }

    function test_revertWhenCallingBridgeMint() public {
        vm.expectRevert(abi.encodeWithSelector(BridgeMintNotImplemented.selector));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        weth.bridgeMint(address(1), 1);
    }

    function test_revertWhenCallingBridgeMintDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        weth.bridgeMint(address(1), 1);
    }

    function test_revertWhenCallingBridgeBurnDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        weth.bridgeBurn(address(1), 1);
    }
}
