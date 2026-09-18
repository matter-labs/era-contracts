// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrividiumTransactionFiltererTest} from "./_PrividiumTransactionFilterer_Shared.t.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
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

        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: sender,
            _contractL2: sender,
            _mintValue: 0,
            _l2Value: 1 ether,
            _l2Calldata: "",
            _refundRecipient: address(0)
        });
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactionAllowedBaseTokenDeposit() public view {
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: sender,
            _contractL2: sender,
            _mintValue: 0,
            _l2Value: 1 ether,
            _l2Calldata: "",
            _refundRecipient: address(0)
        });
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedDepositNotToSelf() public {
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: sender,
            _contractL2: makeAddr("random"),
            _mintValue: 0,
            _l2Value: 1 ether,
            _l2Calldata: "",
            _refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactonAllowedNonBaseTokenDeposit() public view {
        bytes memory depositData = abi.encode(sender, sender, address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: assetRouter,
            _contractL2: L2_ASSET_ROUTER_ADDR,
            _mintValue: 0,
            _l2Value: 0,
            _l2Calldata: txCalladata,
            _refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedNonBaseTokenDepositNotToSelf() public {
        bytes memory depositData = abi.encode(sender, makeAddr("random"), address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: assetRouter,
            _contractL2: L2_ASSET_ROUTER_ADDR,
            _mintValue: 0,
            _l2Value: 0,
            _l2Calldata: txCalladata,
            _refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_ArbitraryTransactionNotAllowed() public {
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: sender,
            _contractL2: makeAddr("contract"),
            _mintValue: 0,
            _l2Value: 0,
            _l2Calldata: txCalladata,
            _refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_ArbitraryTransactionAllowedFromWhitelistedSender() public {
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        vm.prank(owner);
        transactionFiltererProxy.grantWhitelist(sender);
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: sender,
            _contractL2: address(0),
            _mintValue: 0,
            _l2Value: 0,
            _l2Calldata: txCalladata,
            _refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedWhenInvalidSelector() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), makeAddr("random"))
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed({
            _sender: assetRouter,
            _contractL2: L2_ASSET_ROUTER_ADDR,
            _mintValue: 0,
            _l2Value: 0,
            _l2Calldata: txCalladata,
            _refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }
}
