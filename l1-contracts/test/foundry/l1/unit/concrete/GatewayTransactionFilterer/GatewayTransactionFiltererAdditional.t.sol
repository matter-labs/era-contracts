// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {
    GatewayTransactionFilterer,
    MIN_ALLOWED_ADDRESS
} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

/// @notice Additional unit tests for GatewayTransactionFilterer to improve coverage
contract GatewayTransactionFiltererAdditionalTest is Test {
    GatewayTransactionFilterer internal transactionFiltererProxy;
    GatewayTransactionFilterer internal transactionFiltererImplementation;
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal sender = makeAddr("sender");
    address internal bridgehub = makeAddr("bridgehub");
    address internal assetRouter = makeAddr("assetRouter");
    address internal randomUser = makeAddr("randomUser");

    event WhitelistGranted(address indexed sender);
    event WhitelistRevoked(address indexed sender);

    function setUp() public {
        transactionFiltererImplementation = new GatewayTransactionFilterer(IBridgehubBase(bridgehub), assetRouter);

        transactionFiltererProxy = GatewayTransactionFilterer(
            address(
                new TransparentUpgradeableProxy(
                    address(transactionFiltererImplementation),
                    admin,
                    abi.encodeCall(GatewayTransactionFilterer.initialize, owner)
                )
            )
        );
    }

    // ============ Initialize Tests ============

    function test_initialize_revertsOnZeroAddress() public {
        GatewayTransactionFilterer impl = new GatewayTransactionFilterer(IBridgehubBase(bridgehub), assetRouter);

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(GatewayTransactionFilterer.initialize, address(0))
        );
    }

    function test_initialize_setsOwner() public view {
        assertEq(transactionFiltererProxy.owner(), owner);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsBridgehub() public view {
        assertEq(address(transactionFiltererProxy.BRIDGE_HUB()), bridgehub);
    }

    function test_constructor_setsAssetRouter() public view {
        assertEq(transactionFiltererProxy.L1_ASSET_ROUTER(), assetRouter);
    }

    // ============ Event Tests ============

    function test_grantWhitelist_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WhitelistGranted(sender);
        transactionFiltererProxy.grantWhitelist(sender);
    }

    function test_revokeWhitelist_emitsEvent() public {
        vm.startPrank(owner);
        transactionFiltererProxy.grantWhitelist(sender);

        vm.expectEmit(true, false, false, false);
        emit WhitelistRevoked(sender);
        transactionFiltererProxy.revokeWhitelist(sender);
        vm.stopPrank();
    }

    // ============ Access Control Tests ============

    function test_grantWhitelist_revertsIfNotOwner() public {
        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        transactionFiltererProxy.grantWhitelist(sender);
    }

    function test_revokeWhitelist_revertsIfNotOwner() public {
        vm.prank(owner);
        transactionFiltererProxy.grantWhitelist(sender);

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        transactionFiltererProxy.revokeWhitelist(sender);
    }

    // ============ isTransactionAllowed Tests ============

    function test_isTransactionAllowed_allowsHighAddressContracts() public view {
        // contractL2 > MIN_ALLOWED_ADDRESS should always be allowed
        address highAddress = address(uint160(MIN_ALLOWED_ADDRESS) + 1);
        bytes memory txCalldata = hex"12345678";

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser, // non-whitelisted sender
            highAddress,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertTrue(isAllowed, "High address contracts should be allowed");
    }

    function test_isTransactionAllowed_allowsL2AssetRouter() public view {
        // contractL2 == L2_ASSET_ROUTER_ADDR should always be allowed
        bytes memory txCalldata = hex"12345678";

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser, // non-whitelisted sender
            L2_ASSET_ROUTER_ADDR,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertTrue(isAllowed, "L2 Asset Router should be allowed");
    }

    function test_isTransactionAllowed_blocksLowAddressWithoutWhitelist() public view {
        // contractL2 < MIN_ALLOWED_ADDRESS and sender not whitelisted should be blocked
        address lowAddress = address(uint160(MIN_ALLOWED_ADDRESS) - 1);
        bytes memory txCalldata = hex"12345678";

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            lowAddress,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertFalse(isAllowed, "Low address without whitelist should be blocked");
    }

    function test_isTransactionAllowed_allowsLowAddressWithWhitelist() public {
        // contractL2 < MIN_ALLOWED_ADDRESS but sender whitelisted should be allowed
        address lowAddress = address(uint160(MIN_ALLOWED_ADDRESS) - 1);
        bytes memory txCalldata = hex"12345678";

        vm.prank(owner);
        transactionFiltererProxy.grantWhitelist(randomUser);

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            lowAddress,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertTrue(isAllowed, "Whitelisted sender should be allowed to use low addresses");
    }

    function test_isTransactionAllowed_setAssetHandlerAddressWithValidCTM() public {
        // Test setAssetHandlerAddress selector with valid CTM asset ID
        bytes32 validAssetId = bytes32(uint256(0x12345));
        bytes memory txCalldata = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (uint256(1), validAssetId, sender)
        );

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(makeAddr("ctmAddress"))
        );

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalldata,
            address(0)
        );

        assertTrue(isAllowed, "setAssetHandlerAddress with valid CTM should be allowed");
    }

    function test_isTransactionAllowed_setAssetHandlerAddressWithInvalidCTM() public {
        // Test setAssetHandlerAddress selector with invalid CTM asset ID (zero address)
        bytes32 invalidAssetId = bytes32(uint256(0x12345));
        bytes memory txCalldata = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (uint256(1), invalidAssetId, sender)
        );

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdToAddress.selector),
            abi.encode(address(0))
        );

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            assetRouter,
            address(0),
            0,
            0,
            txCalldata,
            address(0)
        );

        assertFalse(isAllowed, "setAssetHandlerAddress with invalid CTM should be blocked");
    }

    // ============ Boundary Tests ============

    function test_isTransactionAllowed_exactlyMinAllowedAddress() public view {
        // contractL2 == MIN_ALLOWED_ADDRESS should NOT be allowed without whitelist
        // since the check is contractL2 > MIN_ALLOWED_ADDRESS
        bytes memory txCalldata = hex"12345678";

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            MIN_ALLOWED_ADDRESS,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertFalse(isAllowed, "Exactly MIN_ALLOWED_ADDRESS should not be allowed without whitelist");
    }

    function test_isTransactionAllowed_justAboveMinAllowedAddress() public view {
        // contractL2 == MIN_ALLOWED_ADDRESS + 1 should be allowed
        address justAbove = address(uint160(MIN_ALLOWED_ADDRESS) + 1);
        bytes memory txCalldata = hex"12345678";

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            justAbove,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertTrue(isAllowed, "Just above MIN_ALLOWED_ADDRESS should be allowed");
    }

    // ============ Fuzz Tests ============

    function testFuzz_isTransactionAllowed_highAddressAlwaysAllowed(address contractL2) public view {
        vm.assume(uint160(contractL2) > uint160(MIN_ALLOWED_ADDRESS));
        vm.assume(contractL2 != L2_ASSET_ROUTER_ADDR); // Skip the special case
        bytes memory txCalldata = hex"12345678";

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            contractL2,
            0,
            0,
            txCalldata,
            address(0)
        );

        assertTrue(isAllowed, "High addresses should always be allowed");
    }

    function testFuzz_whitelist_grantAndRevoke(address senderAddr) public {
        vm.assume(senderAddr != address(0));
        vm.startPrank(owner);

        assertFalse(transactionFiltererProxy.whitelistedSenders(senderAddr));

        transactionFiltererProxy.grantWhitelist(senderAddr);
        assertTrue(transactionFiltererProxy.whitelistedSenders(senderAddr));

        transactionFiltererProxy.revokeWhitelist(senderAddr);
        assertFalse(transactionFiltererProxy.whitelistedSenders(senderAddr));

        vm.stopPrank();
    }
}
