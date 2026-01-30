// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";

import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {InvalidSelector} from "contracts/common/L1ContractErrors.sol";

contract CheckTransactionTest is GatewayTransactionFiltererTest {
    function test_TransactionAllowedOnlyFromWhitelistedSenderWhichIsNotAssetRouter() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), bytes("0x23456"))
        );
        vm.startPrank(owner);
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(address(0)) // Return any address
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            sender,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, false, "Transaction should not be allowed");

        transactionFiltererProxy.grantWhitelist(sender);
        isTxAllowed = transactionFiltererProxy.isTransactionAllowed(sender, address(0), 0, 0, txCalladata, address(0)); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, true, "Transaction should be allowed");

        transactionFiltererProxy.grantWhitelist(assetRouter);
        isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, false, "Transaction should not be allowed");

        vm.stopPrank();
    }

    function test_TransactionAllowedFromWhitelistedSenderForChainBridging() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), bytes("0x23456"))
        );
        vm.startPrank(owner);
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(makeAddr("random")) // Return random address
        );

        transactionFiltererProxy.grantWhitelist(assetRouter);
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, true, "Transaction should be allowed");

        vm.stopPrank();
    }

    function test_TransactionFailsWithInvalidSelectorEvenIfTheSenderIsAR() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), address(0x01234567890123456789))
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidSelector.selector, AssetRouterBase.setAssetHandlerAddressThisChain.selector)
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
    }
}
