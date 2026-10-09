// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrividiumTransactionFiltererTest} from "./_PrividiumTransactionFilterer_Shared.t.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {PrividiumTransactionFilterer} from "contracts/transactionFilterer/PrividiumTransactionFilterer.sol";
import {ITransactionFilterer} from "contracts/state-transition/chain-interfaces/ITransactionFilterer.sol";

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

        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: sender,
            mintValue: 0,
            l2Value: 1 ether,
            l2Calldata: "",
            refundRecipient: address(0)
        });
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactionAllowedBaseTokenDeposit() public view {
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: sender,
            mintValue: 0,
            l2Value: 1 ether,
            l2Calldata: "",
            refundRecipient: address(0)
        });
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedDepositNotToSelf() public {
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: makeAddr("random"),
            mintValue: 0,
            l2Value: 1 ether,
            l2Calldata: "",
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactonAllowedNonBaseTokenDeposit() public view {
        bytes memory depositData = abi.encode(sender, sender, address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: L2_ASSET_ROUTER_ADDR,
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedNonBaseTokenDepositNotToSelf() public {
        bytes memory depositData = abi.encode(sender, makeAddr("random"), address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: L2_ASSET_ROUTER_ADDR,
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_ArbitraryTransactionNotAllowed() public {
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: makeAddr("contract"),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_ArbitraryTransactionAllowedFromWhitelistedSender() public {
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        vm.prank(owner);
        transactionFiltererProxy.grantWhitelist(sender);
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactionRejectedWhenInvalidSelector() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), makeAddr("random"))
        );
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: L2_ASSET_ROUTER_ADDR,
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }
}
