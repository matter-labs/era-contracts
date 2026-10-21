// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1_ANCHOR_MAX_LAG} from "contracts/common/Config.sol";
import {L1AnchorStale} from "contracts/common/L1ContractErrors.sol";

import {L1ReadsHarness} from "./L1Reads.t.sol";
import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice Gating reads only work while the chain's anchor is fresh in L2 block time, and fail closed otherwise.
/// See {protocol-docs/l1sload.md#freshness}.
contract L1AnchorFreshnessTest is L1SloadSharedTest {
    uint256 internal constant ANCHORED_AT = 1_700_000_000;

    L1ReadsHarness internal reads;

    function setUp() public override {
        super.setUp();
        reads = new L1ReadsHarness();
        vm.warp(ANCHORED_AT);
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        _importL1Anchor(1, keccak256("l1 block 1"), ANCHORED_AT);
    }

    /// @dev Up to and including the lag, every check reads L1.
    function test_readsUpToTheLag() public {
        vm.warp(ANCHORED_AT + L1_ANCHOR_MAX_LAG);

        assertTrue(reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID));
        (bool allowed, bytes32 baseTokenAssetId) = reads.sendTarget(
            address(chainRegistrationSender),
            CHAIN_ID,
            PEER_CHAIN_ID
        );
        assertTrue(allowed);
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(reads.baseTokenAssetId(address(chainRegistrationSender), PEER_CHAIN_ID), baseTokenAssetId);
    }

    function test_revertWhen_anchorIsStale() public {
        uint256 now_ = ANCHORED_AT + L1_ANCHOR_MAX_LAG + 1;
        vm.warp(now_);
        bytes memory stale = abi.encodeWithSelector(L1AnchorStale.selector, ANCHORED_AT, now_);

        vm.expectRevert(stale);
        reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID);
        vm.expectRevert(stale);
        reads.sendTarget(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID);
        vm.expectRevert(stale);
        reads.baseTokenAssetId(address(chainRegistrationSender), PEER_CHAIN_ID);
    }

    /// @dev Priority Mode batches can't import anchors, so the chain's reads fail closed once its last anchor is past
    /// the lag, however the L1 state changed meanwhile.
    function test_priorityModeReadsFailClosedAfterTheLag() public {
        // Priority Mode starts; the chain imports nothing from here on, while L1 suspends the peer.
        vm.prank(governance);
        chainRegistrationSender.suspendInterop(PEER_CHAIN_ID);
        assertTrue(reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID), "the old view");

        vm.warp(ANCHORED_AT + L1_ANCHOR_MAX_LAG + 1);
        vm.expectRevert(
            abi.encodeWithSelector(L1AnchorStale.selector, ANCHORED_AT, ANCHORED_AT + L1_ANCHOR_MAX_LAG + 1)
        );
        reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID);
    }

    /// @dev A newer anchor makes the reads work again, at the newer L1 state.
    function test_newerAnchorRestoresReads() public {
        vm.prank(governance);
        chainRegistrationSender.suspendInterop(PEER_CHAIN_ID);
        uint256 later = ANCHORED_AT + 2 * L1_ANCHOR_MAX_LAG;
        vm.warp(later);

        _importL1Anchor(2, keccak256("l1 block 2"), later);

        assertFalse(reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @dev Reads fail exactly past the lag, for any age.
    function testFuzz_readsFailExactlyPastTheLag(uint256 _age) public {
        uint256 age = bound(_age, 0, 10 * L1_ANCHOR_MAX_LAG);
        vm.warp(ANCHORED_AT + age);

        if (age > L1_ANCHOR_MAX_LAG) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, ANCHORED_AT, ANCHORED_AT + age));
        }
        reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID);
    }
}

/// @notice A chain that never imported an anchor reads nothing.
contract L1AnchorFreshnessWithoutAnchorTest is L1SloadSharedTest {
    function test_revertWhen_noAnchorWasImported() public {
        L1ReadsHarness reads = new L1ReadsHarness();
        vm.warp(L1_ANCHOR_MAX_LAG + 1);

        vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, 0, L1_ANCHOR_MAX_LAG + 1));
        reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID);
    }
}
