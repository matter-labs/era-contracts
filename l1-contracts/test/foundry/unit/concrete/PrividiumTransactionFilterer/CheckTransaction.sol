// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrividiumTransactionFiltererTest} from "./_PrividiumTransactionFilterer_Shared.t.sol";

import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {InvalidSelector} from "contracts/common/L1ContractErrors.sol";
import {IL2SharedBridgeLegacyFunctions} from "contracts/bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";

contract CheckTransactionTest is PrividiumTransactionFiltererTest {
    function test_TransactionAllowedBaseTokenDeposit() public view {
        address depositor = address(0x12345678901234567890); // random address
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            depositor,
            address(0),
            0,
            1 ether,
            "",
            address(0)
        ); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactonAllowedNonBaseTokenDeposit() public {
        address depositor = address(0x12345678901234567890); // random address
        bytes memory depositData = abi.encode(depositor, address(0), address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(address(0)) // asset is not a chain
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_TransactonRejectedChainMigration() public {
        address depositor = address(0x12345678901234567890); // random address
        bytes memory depositData = abi.encode(depositor, address(0), address(0), 1 ether, "");
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (uint256(10), bytes32("0x12345"), depositData)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(address(0x123123)) // asset IS a chain
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_TransactonAllowedNonBaseTokenDepositLegacyInterface() public view {
        address depositor = address(0x12345678901234567890); // random address
        bytes memory txCalladata = abi.encodeCall(
            IL2SharedBridgeLegacyFunctions.finalizeDeposit,
            (depositor, address(0), address(0), 1 ether, "")
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertTrue(isTxAllowed, "Transaction should be allowed");
    }

    function test_ArbitraryTransactionNotAllowed() public view {
        address sender = address(0x12345678901234567890); // random address
        bytes memory txCalladata = abi.encodeWithSelector(bytes4(0xdeadbeef), "0x12345");
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            sender,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }

    function test_ArbitraryTransactionAllowedFromWhitelistedSender() public {
        address sender = address(0x12345678901234567890); // random address
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

    function test_TransactionRejectedWhenInvalidSelector() public view {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), address(0x01234567890123456789))
        );
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalladata,
            address(0)
        ); // Other arguments do not make a difference for the test
        assertFalse(isTxAllowed, "Transaction should not be allowed");
    }
}
