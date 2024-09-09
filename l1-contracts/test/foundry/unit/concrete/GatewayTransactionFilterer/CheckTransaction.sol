// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IL2Bridge} from "contracts/bridge/interfaces/IL2Bridge.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {AlreadyWhitelisted, NotWhitelisted} from "contracts/common/L1ContractErrors.sol";

contract CheckTransactionTest is GatewayTransactionFiltererTest {
    function test_TransactionAllowedOnlyFromWhitelistedSenderWhichIsNotBaseTokenBridge() public {
        address baseTokenBridge = address(0x4040404);
        address bridgehub = address(0x5050505);
        // address stm = address(0x6060606);
        bytes memory txCalladata = abi.encodeCall(IL2Bridge.finalizeDeposit, (bytes32("0x12345"), bytes("0x23456")));
        vm.startPrank(owner);
        vm.mockCall(
            address(owner),
            abi.encodeWithSelector(IGetters.getBaseTokenBridge.selector),
            abi.encode(baseTokenBridge) // Return address which is not the sender
        );
        vm.mockCall(
            address(owner),
            abi.encodeWithSelector(IGetters.getBridgehub.selector),
            abi.encode(bridgehub) // Return address of bridgehub
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehub.stmAssetIdToAddress.selector),
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

        transactionFiltererProxy.grantWhitelist(baseTokenBridge);
        isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            baseTokenBridge,
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
        address baseTokenBridge = address(0x4040404);
        address bridgehub = address(0x5050505);
        address stm = address(0x6060606);
        bytes memory txCalladata = abi.encodeCall(IL2Bridge.finalizeDeposit, (bytes32("0x12345"), bytes("0x23456")));
        vm.startPrank(owner);
        vm.mockCall(
            address(owner),
            abi.encodeWithSelector(IGetters.getBaseTokenBridge.selector),
            abi.encode(baseTokenBridge) // Return address which is not the sender
        );
        vm.mockCall(
            address(owner),
            abi.encodeWithSelector(IGetters.getBridgehub.selector),
            abi.encode(bridgehub) // Return address of bridgehub
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehub.stmAssetIdToAddress.selector),
            abi.encode(stm) // Return random address
        );

        transactionFiltererProxy.grantWhitelist(baseTokenBridge);
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            baseTokenBridge,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, true, "Transaction should be allowed");

        vm.stopPrank();
    }
}
