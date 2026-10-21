// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SharedL2ContractL1Deployer} from "./_SharedL2ContractL1Deployer.sol";
import {L1SloadTestUtils} from "../../unit/concrete/Interop/L1Sload/L1SloadTestUtils.sol";

/// @title L2BridgehubAliasRegressionL1Test
/// @notice L1 context test for the `chainRegistrationSender` alias regression (PR #1765), carried over to the L1 reads:
/// the L2 Bridgehub stores the aliased L1 `ChainRegistrationSender`, and must read the L1 state at the unaliased
/// address. See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
/// @dev The L1 `ChainRegistrationSender` is not deployed in this context; {L1SloadTestUtils} writes its state.
contract L2BridgehubAliasRegressionL1Test is Test, SharedL2ContractL1Deployer {
    // The L1 address of the chain registration sender
    address internal l1ChainRegistrationSender;
    // The aliased version (as the L2 Bridgehub stores it)
    address internal aliasedChainRegistrationSender;

    function setUp() public virtual override {
        super.setUp();

        aliasedChainRegistrationSender = L2Bridgehub(L2_BRIDGEHUB_ADDR).chainRegistrationSender();
        l1ChainRegistrationSender = AddressAliasHelper.undoL1ToL2Alias(aliasedChainRegistrationSender);
    }

    /// @notice The L2 Bridgehub reports the unaliased address as the L1 `ChainRegistrationSender`.
    function test_regression_l1ChainRegistrationSenderIsUnaliased() public view {
        assertNotEq(aliasedChainRegistrationSender, address(0), "chainRegistrationSender should be set");
        assertEq(L2Bridgehub(L2_BRIDGEHUB_ADDR).l1ChainRegistrationSender(), l1ChainRegistrationSender);
        assertEq(
            AddressAliasHelper.applyL1ToL2Alias(l1ChainRegistrationSender),
            aliasedChainRegistrationSender,
            "Aliasing should be reversible"
        );
        assertNotEq(
            l1ChainRegistrationSender,
            aliasedChainRegistrationSender,
            "L1 address and aliased address should be different"
        );
    }

    /// @notice A peer allowed at the unaliased (L1) address is allowed.
    function test_regression_readsTheUnaliasedAddress() public {
        uint256 testChainId = 12345;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0xABCDEF));

        L1SloadTestUtils.allowInteropPair(
            l1ChainRegistrationSender,
            block.chainid,
            baseTokenAssetId,
            testChainId,
            testBaseTokenAssetId
        );

        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId), "the peer must be allowed");
        (bool allowed, bytes32 peerBaseTokenAssetId) = L2Bridgehub(L2_BRIDGEHUB_ADDR).interopSendTarget(testChainId);
        assertTrue(allowed);
        assertEq(peerBaseTokenAssetId, testBaseTokenAssetId);
        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isInteropRegistered(testChainId));
    }

    /// @notice State at the aliased address, which is no L1 contract, is never read.
    function test_regression_ignoresTheAliasedAddress() public {
        uint256 testChainId = 12346;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x123456));

        L1SloadTestUtils.allowInteropPair(
            aliasedChainRegistrationSender,
            block.chainid,
            baseTokenAssetId,
            testChainId,
            testBaseTokenAssetId
        );

        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));
        (bool allowed, bytes32 peerBaseTokenAssetId) = L2Bridgehub(L2_BRIDGEHUB_ADDR).interopSendTarget(testChainId);
        assertFalse(allowed);
        assertEq(peerBaseTokenAssetId, bytes32(0));
        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isInteropRegistered(testChainId));
    }

    /// @notice Deregistration at the L1 address refuses the peer.
    function test_deregisteredPeerIsRefused() public {
        uint256 testChainId = 12355;
        L1SloadTestUtils.allowInteropPair(
            l1ChainRegistrationSender,
            block.chainid,
            baseTokenAssetId,
            testChainId,
            bytes32(uint256(0x8642))
        );

        L1SloadTestUtils.deregisterInteropPeer(l1ChainRegistrationSender, block.chainid, testChainId);

        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));
        (bool allowed, ) = L2Bridgehub(L2_BRIDGEHUB_ADDR).interopSendTarget(testChainId);
        assertFalse(allowed);
        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isInteropRegistered(testChainId), "the snapshot stays");
    }

    /// @notice Fuzz test with various chain IDs and asset IDs
    function testFuzz_regression_readsTheUnaliasedAddressForVariousPeers(
        uint256 testChainId,
        bytes32 testBaseTokenAssetId
    ) public {
        vm.assume(testChainId != block.chainid);
        // The shared setUp allowed the interop destination already.
        vm.assume(testChainId != INTEROP_DESTINATION_CHAIN_ID);
        // Keep the snapshot observable rather than accepting the mapping's default value.
        vm.assume(testBaseTokenAssetId != bytes32(0));
        assertFalse(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId));

        L1SloadTestUtils.allowInteropPair(
            l1ChainRegistrationSender,
            block.chainid,
            baseTokenAssetId,
            testChainId,
            testBaseTokenAssetId
        );

        assertTrue(L2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(testChainId), "fuzzed peer must be allowed");
        (, bytes32 peerBaseTokenAssetId) = L2Bridgehub(L2_BRIDGEHUB_ADDR).interopSendTarget(testChainId);
        assertEq(peerBaseTokenAssetId, testBaseTokenAssetId, "fuzzed snapshot must be read");
    }
}
