// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AlreadyWhitelisted, InvalidSelector, NotWhitelisted} from "contracts/common/L1ContractErrors.sol";

contract CheckTransactionTest is GatewayTransactionFiltererTest {
    function test_TransactionAllowedOnlyFromWhitelistedSenderWhichIsNotAssetRouter() public {
        bytes memory txCalladata = abi.encodeCall(
            IAssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), bytes("0x23456"))
        );
        vm.startPrank(owner);
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehub.ctmAssetIdToAddress.selector),
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
        address stm = address(0x6060606);
        bytes memory txCalladata = abi.encodeCall(
            IAssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), bytes("0x23456"))
        );
        vm.startPrank(owner);
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehub.ctmAssetIdToAddress.selector),
            abi.encode(stm) // Return random address
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
            IAssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), address(0x01234567890123456789))
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidSelector.selector, IAssetRouterBase.setAssetHandlerAddressThisChain.selector)
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
