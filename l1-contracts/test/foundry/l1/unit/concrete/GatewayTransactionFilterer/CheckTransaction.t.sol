// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {MIN_ALLOWED_ADDRESS} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InvalidSelector} from "contracts/common/L1ContractErrors.sol";
import {ITransactionFilterer} from "contracts/state-transition/chain-interfaces/ITransactionFilterer.sol";

/// @dev The bridgehub is a bare address: tests mock its `ctmAssetIdToAddress` to pick whether the
/// asset id belongs to a registered CTM.
contract GatewayTransactionFiltererCheckTransactionTest is GatewayTransactionFiltererTest {
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
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, false, "Transaction should not be allowed");

        transactionFiltererProxy.grantWhitelist(sender);
        isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: sender,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, true, "Transaction should be allowed");

        transactionFiltererProxy.grantWhitelist(assetRouter);
        isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test

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
        bool isTxAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, true, "Transaction should be allowed");

        vm.stopPrank();
    }

    function test_TransactionFailsWithInvalidSelectorEvenIfTheSenderIsAR() public {
        bytes memory txCalladata = abi.encodeCall(
            AssetRouterBase.setAssetHandlerAddressThisChain,
            (bytes32("0x12345"), makeAddr("testAddress"))
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidSelector.selector, AssetRouterBase.setAssetHandlerAddressThisChain.selector)
        );
        ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalladata,
            refundRecipient: address(0)
        }); // Other arguments do not make a difference for the test
    }

    function test_isTransactionAllowed_allowsL2AssetRouter() public view {
        bool isAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: randomUser, // non-whitelisted sender
            contractL2: L2_ASSET_ROUTER_ADDR,
            mintValue: 0,
            l2Value: 0,
            l2Calldata: hex"12345678",
            refundRecipient: address(0)
        });

        assertTrue(isAllowed, "L2 Asset Router should be allowed");
    }

    function test_isTransactionAllowed_setAssetHandlerAddressWithValidCTM() public {
        bytes memory txCalldata = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (uint256(1), bytes32(uint256(0x12345)), sender)
        );

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(makeAddr("ctmAddress"))
        );

        bool isAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalldata,
            refundRecipient: address(0)
        });

        assertTrue(isAllowed, "setAssetHandlerAddress with valid CTM should be allowed");
    }

    function test_isTransactionAllowed_setAssetHandlerAddressWithInvalidCTM() public {
        bytes memory txCalldata = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (uint256(1), bytes32(uint256(0x12345)), sender)
        );

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(address(0))
        );

        bool isAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: assetRouter,
            contractL2: address(0),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: txCalldata,
            refundRecipient: address(0)
        });

        assertFalse(isAllowed, "setAssetHandlerAddress with invalid CTM should be blocked");
    }

    function test_isTransactionAllowed_exactlyMinAllowedAddress() public view {
        // The bound is exclusive: MIN_ALLOWED_ADDRESS itself is still a built-in address.
        bool isAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: randomUser,
            contractL2: MIN_ALLOWED_ADDRESS,
            mintValue: 0,
            l2Value: 0,
            l2Calldata: hex"12345678",
            refundRecipient: address(0)
        });

        assertFalse(isAllowed, "Exactly MIN_ALLOWED_ADDRESS should not be allowed without whitelist");
    }

    function test_isTransactionAllowed_justAboveMinAllowedAddress() public view {
        bool isAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: randomUser,
            contractL2: address(uint160(MIN_ALLOWED_ADDRESS) + 1),
            mintValue: 0,
            l2Value: 0,
            l2Calldata: hex"12345678",
            refundRecipient: address(0)
        });

        assertTrue(isAllowed, "Just above MIN_ALLOWED_ADDRESS should be allowed");
    }

    function testFuzz_isTransactionAllowed_highAddressAlwaysAllowed(address _contractL2) public view {
        vm.assume(uint160(_contractL2) > uint160(MIN_ALLOWED_ADDRESS));
        vm.assume(_contractL2 != ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR); // registered as dangerous on init

        bool isAllowed = ITransactionFilterer(address(transactionFiltererProxy)).isTransactionAllowed({
            sender: randomUser,
            contractL2: _contractL2,
            mintValue: 0,
            l2Value: 0,
            l2Calldata: hex"12345678",
            refundRecipient: address(0)
        });

        assertTrue(isAllowed, "High addresses should always be allowed");
    }
}
