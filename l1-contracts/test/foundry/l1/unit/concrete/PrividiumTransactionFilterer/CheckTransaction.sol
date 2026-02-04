// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrividiumTransactionFiltererTest} from "./_PrividiumTransactionFilterer_Shared.t.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {InvalidSelector} from "contracts/common/L1ContractErrors.sol";
import {IL2SharedBridgeLegacyFunctions} from "contracts/bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {PrividiumTransactionFilterer} from "contracts/transactionFilterer/PrividiumTransactionFilterer.sol";

contract CheckTransactionTest is PrividiumTransactionFiltererTest {
    function test_DepositsAllowed() public {
        bool depositsAllowed = transactionFiltererProxy.depositsAllowed();
        assertTrue(depositsAllowed, "Deposits should be allowed");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PrividiumTransactionFilterer.DepositsPermissionChanged(false);
        transactionFiltererProxy.setDepositsAllowed(false);

        depositsAllowed = transactionFiltererProxy.depositsAllowed();
        assertFalse(depositsAllowed, "Deposits should not be allowed after disabling them");
    }

    function test_DepositWhileDepositsNotAllowed() public {
        vm.prank(owner);
        transactionFiltererProxy.setDepositsAllowed(false);

        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(sender, sender, 0, 1 ether, "", address(0));
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactionAllowedBaseTokenDeposit() public view {
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(sender, sender, 0, 1 ether, "", address(0));
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedDepositNotToSelf() public {
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            sender,
            makeAddr("random"),
            0,
            1 ether,
            "",
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactonAllowedNonBaseTokenDeposit() public view {
        bytes memory depositData = abi.encode(sender, sender, address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            L2_ASSET_ROUTER_ADDR,
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedNonBaseTokenDepositNotToSelf() public {
        bytes memory depositData = abi.encode(sender, makeAddr("random"), address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            L2_ASSET_ROUTER_ADDR,
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactonAllowedNonBaseTokenDepositLegacyInterface() public {
        bytes memory txCalladata = abi.encodeCall(
            IL2SharedBridgeLegacyFunctions.finalizeDeposit,
            (sender, sender, makeAddr("token"), 1 ether, "")
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            L2_ASSET_ROUTER_ADDR,
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_ArbitraryTransactionNotAllowed() public {
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            sender,
            makeAddr("contract"),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_ArbitraryTransactionAllowedFromWhitelistedSender() public {
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        vm.prank(owner);
        transactionFiltererProxy.grantWhitelist(sender);
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            sender,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedWhenInvalidSelector() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), makeAddr("random"))
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            L2_ASSET_ROUTER_ADDR,
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }
}
