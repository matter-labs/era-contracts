// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {ChainFeature} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {EmptyAssetId, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SharedL2ContractL1Deployer} from "./_SharedL2ContractL1Deployer.sol";

/// @title L2BridgehubAliasRegressionL1Test
/// @notice L1 context test for L2Bridgehub onlyChainRegistrationSender alias regression (PR #1765)
/// @dev Tests that the modifier correctly compares msg.sender directly against chainRegistrationSender
///      instead of applying undoL1ToL2Alias to chainRegistrationSender
contract L2BridgehubAliasRegressionL1Test is Test, SharedL2ContractL1Deployer {
    // The L1 address that will be the chain registration sender
    address internal l1ChainRegistrationSender;
    // The aliased version (as it appears on L2)
    address internal aliasedChainRegistrationSender;

    function setUp() public virtual override {
        super.setUp();

        // Get the stored chainRegistrationSender from L2Bridgehub
        aliasedChainRegistrationSender = L2Bridgehub(L2_BRIDGEHUB_ADDR).chainRegistrationSender();

        // Calculate what the original L1 address would be
        l1ChainRegistrationSender = AddressAliasHelper.undoL1ToL2Alias(aliasedChainRegistrationSender);
    }

    /// @notice Test that the aliased sender can successfully call allowInteropPeer
    /// @dev This is the correct behavior after the fix
    function test_regression_aliasedSenderCanAllowPeer() public {
        uint256 testChainId = 12345;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0xABCDEF));

        // Verify that aliasedChainRegistrationSender is set and is what we expect
        assertNotEq(aliasedChainRegistrationSender, address(0), "chainRegistrationSender should be set");

        vm.prank(aliasedChainRegistrationSender);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);

        assertEq(
            L2Bridgehub(L2_BRIDGEHUB_ADDR).baseTokenAssetId(testChainId),
            testBaseTokenAssetId,
            "aliased sender registration must persist"
        );
        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId), "aliased sender must allow the peer");
    }

    /// @notice Test that the non-aliased (original L1) address cannot call allowInteropPeer
    /// @dev Before the fix, the buggy modifier would have checked against this address
    function test_regression_nonAliasedSenderCannotAllowPeer() public {
        uint256 testChainId = 12346;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x123456));

        // The non-aliased address (original L1 address) should NOT be able to call
        vm.prank(l1ChainRegistrationSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, l1ChainRegistrationSender));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);
    }

    /// @notice Test that SERVICE_TRANSACTION_SENDER can still call allowInteropPeer
    /// @dev The modifier has a special bypass for SERVICE_TRANSACTION_SENDER
    function test_regression_serviceTransactionSenderCanAllowPeer() public {
        uint256 testChainId = 12347;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x789ABC));

        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);

        assertEq(
            L2Bridgehub(L2_BRIDGEHUB_ADDR).baseTokenAssetId(testChainId),
            testBaseTokenAssetId,
            "service sender registration must persist"
        );
        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId), "service sender must allow the peer");
    }

    /// @notice Test that random addresses cannot call allowInteropPeer
    function test_regression_randomAddressCannotAllowPeer() public {
        uint256 testChainId = 12348;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0xDEADBEEF));
        address randomAddress = makeAddr("randomAddress");

        vm.prank(randomAddress);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomAddress));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);
    }

    /// @notice Test demonstrating the aliasing relationship
    /// @dev This unit test verifies the address aliasing math
    function test_regression_aliasingRelationship() public view {
        // Verify the aliasing relationship
        address reAliased = AddressAliasHelper.applyL1ToL2Alias(l1ChainRegistrationSender);
        assertEq(reAliased, aliasedChainRegistrationSender, "Aliasing should be reversible");

        // Verify that the stored chainRegistrationSender is different from the L1 address
        // (This would only be equal if the address was never aliased, which is not the case on L2)
        assertNotEq(
            l1ChainRegistrationSender,
            aliasedChainRegistrationSender,
            "L1 address and aliased address should be different"
        );
    }

    /// @notice Fuzz test with various chain IDs and asset IDs
    /// @dev Ensures the modifier works correctly for any peer
    function testFuzz_regression_aliasedSenderCanAllowVariousPeers(
        uint256 testChainId,
        bytes32 testBaseTokenAssetId
    ) public {
        // Avoid chainId 0 which might have special meaning
        vm.assume(testChainId > 0);
        // Shared setup scopes a `baseTokenAssetId` call mock to the interop destination while
        // constructing its example chain. A write to that key is real, but the mocked getter
        // deliberately keeps returning the setup value, so it cannot observe this assertion.
        vm.assume(testChainId != INTEROP_DESTINATION_CHAIN_ID);
        // Keep the storage assertion observable rather than accepting the mapping's default value.
        vm.assume(testBaseTokenAssetId != bytes32(0));

        vm.prank(aliasedChainRegistrationSender);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);

        assertEq(
            L2Bridgehub(L2_BRIDGEHUB_ADDR).baseTokenAssetId(testChainId),
            testBaseTokenAssetId,
            "fuzzed registration must persist"
        );
        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId), "fuzzed peer must be allowed");
    }

    /// @notice Fuzz test that random addresses are always rejected
    /// @dev Ensures the modifier correctly rejects unauthorized callers
    function testFuzz_regression_randomAddressesCannotAllowPeer(address randomCaller) public {
        // Exclude the valid callers
        vm.assume(randomCaller != aliasedChainRegistrationSender);
        vm.assume(randomCaller != SERVICE_TRANSACTION_SENDER);

        uint256 testChainId = 99999;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x12345));

        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);

        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));
    }

    function test_allowInteropPeer_revertWhen_emptyAssetId() public {
        uint256 testChainId = 12354;

        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(EmptyAssetId.selector);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, bytes32(0));

        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));
    }

    /// @notice Deregistration removes an allowed peer: its base token and its allowance.
    function test_deregisterChainForInterop_allowedPeer() public {
        uint256 testChainId = 12355;
        vm.prank(aliasedChainRegistrationSender);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, bytes32(uint256(0x8642)));

        vm.prank(aliasedChainRegistrationSender);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).deregisterChainForInterop(testChainId);

        assertEq(L2Bridgehub(L2_BRIDGEHUB_ADDR).baseTokenAssetId(testChainId), bytes32(0));
        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));
    }

    function testFuzz_deregisterChainForInterop_revertWhen_unauthorized(address _caller) public {
        vm.assume(_caller != aliasedChainRegistrationSender);
        vm.assume(_caller != SERVICE_TRANSACTION_SENDER);
        uint256 testChainId = 12357;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x9753));
        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).allowInteropPeer(testChainId, testBaseTokenAssetId);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).deregisterChainForInterop(testChainId);

        assertEq(L2Bridgehub(L2_BRIDGEHUB_ADDR).baseTokenAssetId(testChainId), testBaseTokenAssetId);
        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));
    }

    /// @notice The L1 `ChainRegistrationSender` pushes a chain's features to its own L2 Bridgehub
    /// ({protocol-docs/interop-gating.md#chain-features}); the aliased sender can set them and turn them off again.
    function test_setChainFeatureEnabled_byAliasedSender() public {
        L2Bridgehub l2Bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);
        assertFalse(l2Bridgehub.isChainFeatureEnabled(ChainFeature.ExpirableTransfers), "features start disabled");

        vm.prank(aliasedChainRegistrationSender);
        l2Bridgehub.setChainFeatureEnabled(ChainFeature.ExpirableTransfers, true);
        assertTrue(l2Bridgehub.isChainFeatureEnabled(ChainFeature.ExpirableTransfers));

        vm.prank(aliasedChainRegistrationSender);
        l2Bridgehub.setChainFeatureEnabled(ChainFeature.ExpirableTransfers, false);
        assertFalse(l2Bridgehub.isChainFeatureEnabled(ChainFeature.ExpirableTransfers));
    }

    function test_setChainFeatureEnabled_revertWhen_notChainRegistrationSender() public {
        vm.prank(l1ChainRegistrationSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, l1ChainRegistrationSender));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setChainFeatureEnabled(ChainFeature.ExpirableTransfers, true);
    }
}
