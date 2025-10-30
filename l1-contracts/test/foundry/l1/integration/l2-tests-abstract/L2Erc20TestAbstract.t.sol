// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";

import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {InteropCall, InteropCallStarter} from "contracts/common/Messaging.sol";

import {InteropLibrary} from "contracts/interop/InteropLibrary.sol";

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

    function test_requestTokenTransferInteropViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        uint256 destinationChainId = 271;

        vm.deal(address(this), 1000 ether);

        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );

        InteropLibrary.sendToken(destinationChainId, l2TokenAddress, 100, address(this));
    }

    function test_requestSendCallViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        uint256 destinationChainId = 271;
        vm.deal(address(this), 1000 ether);

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), 0))
        );

        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );

        InteropLibrary.sendCall(destinationChainId, L2_ASSET_ROUTER_ADDR, address(0), secondBridgeCalldata);
    }
}
