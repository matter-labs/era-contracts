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
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
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
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

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

    function test_withdrawTokenNoRegistration() public {
        TestnetERC20Token l2NativeToken = new TestnetERC20Token("token", "T", 18);

        l2NativeToken.mint(address(this), 100);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, 100);

        // Basically we want all L2->L1 transactions to pass
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSignature("sendToL1(bytes)"),
            abi.encode(bytes32(uint256(1)))
        );

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(l2NativeToken));

        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(
            assetId,
            DataEncoding.encodeBridgeBurnData(100, address(1), address(l2NativeToken))
        );
    }
}
