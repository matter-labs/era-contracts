// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {L1_ANCHOR_MAX_LAG} from "contracts/common/Config.sol";
import {L1AnchorTooOld} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @dev Exposes the freshness rule, which the execute flow applies per batch (`L1Anchors.t.sol` runs it through a
/// real diamond). Isolating it lets the tests reach batches committed before v36, whose stored timestamp is 0 and
/// which a v36 Committer can't produce, and drive long sequences of batches.
contract L1AnchorFreshnessHarness is ExecutorFacet {
    function setPriorityModeActivated(bool _activated) external {
        s.priorityModeInfo.activated = _activated;
    }

    function checkL1AnchorFreshness(uint256 _batchTimestamp, uint256 _newestL1AnchorTimestamp) external {
        _checkL1AnchorFreshness(_batchTimestamp, _newestL1AnchorTimestamp);
    }

    function l1AnchorTimestamp() external view returns (uint256) {
        return s.l1AnchorTimestamp;
    }
}

/// @notice The anchor freshness rule. See {protocol-docs/l1sload.md#freshness}.
contract L1AnchorFreshnessTest is Test {
    uint256 internal constant ANCHORED_AT = 1_700_000_000;

    L1AnchorFreshnessHarness internal harness;

    function setUp() public {
        harness = new L1AnchorFreshnessHarness();
    }

    /// @dev A batch committed before v36 stores timestamp 0, so it executes whatever the anchor's age.
    function test_batchCommittedBeforeTheUpgradeIsNotChecked() public {
        harness.checkL1AnchorFreshness(ANCHORED_AT + 1, ANCHORED_AT);

        harness.checkL1AnchorFreshness(0, 0);
        assertEq(harness.l1AnchorTimestamp(), ANCHORED_AT, "the anchor is kept");
    }

    function test_revertWhen_batchIsPastTheLag() public {
        harness.checkL1AnchorFreshness(ANCHORED_AT, ANCHORED_AT);
        uint256 batchTimestamp = ANCHORED_AT + L1_ANCHOR_MAX_LAG + 1;

        vm.expectRevert(abi.encodeWithSelector(L1AnchorTooOld.selector, ANCHORED_AT, batchTimestamp));
        harness.checkL1AnchorFreshness(batchTimestamp, 0);
    }

    /// @dev The batch's own anchor counts, even when it is the chain's first.
    function test_batchImportingItsFirstAnchorIsChecked() public {
        uint256 batchTimestamp = ANCHORED_AT + L1_ANCHOR_MAX_LAG + 1;
        vm.expectRevert(abi.encodeWithSelector(L1AnchorTooOld.selector, ANCHORED_AT, batchTimestamp));
        harness.checkL1AnchorFreshness(batchTimestamp, ANCHORED_AT);
    }

    /// @dev Executes iff the chain has no anchor, is in Priority Mode, the batch predates v36, or the newest anchor
    /// (the chain's or the batch's) is within the lag. The stored anchor only grows, and a revert leaves it in place.
    function testFuzz_executesIffFresh(
        uint64 _storedAnchor,
        uint64 _batchAnchor,
        uint64 _batchTimestamp,
        bool _priorityMode
    ) public {
        if (_storedAnchor != 0) {
            harness.checkL1AnchorFreshness(0, _storedAnchor);
        }
        harness.setPriorityModeActivated(_priorityMode);
        uint256 newest = _batchAnchor > _storedAnchor ? _batchAnchor : _storedAnchor;
        bool fresh = newest == 0 || _priorityMode || uint256(newest) + L1_ANCHOR_MAX_LAG >= _batchTimestamp;

        if (!fresh) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorTooOld.selector, newest, _batchTimestamp));
        }
        harness.checkL1AnchorFreshness(_batchTimestamp, _batchAnchor);
        assertEq(harness.l1AnchorTimestamp(), fresh ? newest : _storedAnchor);
    }
}

/// @dev Executes random batches against the freshness rule and tracks what the chain's newest anchor must be.
contract L1AnchorFreshnessHandler is Test {
    L1AnchorFreshnessHarness internal immutable HARNESS;

    uint256 public newestAnchor;
    uint256 public executed;
    uint256 public refused;

    constructor(L1AnchorFreshnessHarness _harness) {
        HARNESS = _harness;
    }

    /// @param _anchorDelta How far the batch's own anchor is from the newest one, zero for none.
    /// @param _batchDelta How far after the newest anchor the batch's last L2 block is, or zero for a pre-v36 batch.
    function executeBatch(uint256 _anchorDelta, uint256 _batchDelta, bool _priorityMode) external {
        uint256 batchAnchor = bound(_anchorDelta, 0, 2 * L1_ANCHOR_MAX_LAG);
        if (batchAnchor != 0) {
            // Older than the newest one half of the time: L2 needn't import anchors in increasing order.
            batchAnchor = _anchorDelta % 2 == 0
                ? newestAnchor + batchAnchor
                : _saturatingSub(newestAnchor, batchAnchor);
        }
        uint256 newest = batchAnchor > newestAnchor ? batchAnchor : newestAnchor;
        uint256 batchTimestamp = bound(_batchDelta, 0, 2 * L1_ANCHOR_MAX_LAG);
        if (batchTimestamp != 0) {
            batchTimestamp += newest;
        }
        HARNESS.setPriorityModeActivated(_priorityMode);

        if (newest != 0 && !_priorityMode && newest + L1_ANCHOR_MAX_LAG < batchTimestamp) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorTooOld.selector, newest, batchTimestamp));
            HARNESS.checkL1AnchorFreshness(batchTimestamp, batchAnchor);
            ++refused;
            return;
        }
        HARNESS.checkL1AnchorFreshness(batchTimestamp, batchAnchor);
        newestAnchor = newest;
        ++executed;
    }

    function _saturatingSub(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a > _b ? _a - _b : 0;
    }
}

/// @notice The chain's newest anchor timestamp is the maximum over its executed batches, whatever their order.
contract L1AnchorFreshnessInvariantTest is Test {
    L1AnchorFreshnessHarness internal harness;
    L1AnchorFreshnessHandler internal handler;
    uint256 internal lastSeen;

    function setUp() public {
        harness = new L1AnchorFreshnessHarness();
        handler = new L1AnchorFreshnessHandler(harness);
        targetContract(address(handler));
    }

    function invariant_newestAnchorIsTheMaximumExecuted() public view {
        assertEq(harness.l1AnchorTimestamp(), handler.newestAnchor());
    }

    function invariant_newestAnchorNeverDecreases() public {
        uint256 current = harness.l1AnchorTimestamp();
        assertGe(current, lastSeen);
        lastSeen = current;
    }
}
