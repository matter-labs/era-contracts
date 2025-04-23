// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Import Foundry's Test framework
import {Test} from "forge-std/Test.sol";

import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";

import {ZeroAddress, TimerAlreadyStarted, CallerNotTimerAdmin, DeadlineNotYetPassed, NewDeadlineNotGreaterThanCurrent, NewDeadlineExceedsMaxDeadline} from "contracts/common/L1ContractErrors.sol";

contract GovernanceUpgradeTimerTest is Test {
    // Instance of the contract under test
    GovernanceUpgradeTimer timer;

    // Addresses used in tests
    address owner = address(0x1);
    address newOwner = address(0x2);
    address timerGovernance = address(0x3);
    address nonAdmin = address(0x4);
    address anotherAddress = address(0x5);

    // Immutable parameters for the contract
    uint256 initialDelay = 1000; // seconds
    uint256 maxAdditionalDelay = 2000; // seconds

    // Events from the GovernanceUpgradeTimer contract
    event TimerStarted(uint256 deadline, uint256 maxDeadline);
    event DeadlineChanged(uint256 newDeadline);

    // setUp is run before each test
    function setUp() public {
        // Deploy the contract as the owner
        vm.startPrank(owner);
        timer = new GovernanceUpgradeTimer(initialDelay, maxAdditionalDelay, timerGovernance, owner);
        vm.stopPrank();
    }

    /* ========== Deployment Tests ========== */

    function testDeploymentSetsImmutableVariablesCorrectly() public {
        assertEq(timer.INITIAL_DELAY(), initialDelay, "INITIAL_DELAY should be set correctly");
        assertEq(timer.MAX_ADDITIONAL_DELAY(), maxAdditionalDelay, "MAX_ADDITIONAL_DELAY should be set correctly");
        assertEq(timer.TIMER_GOVERNANCE(), timerGovernance, "TIMER_GOVERNANCE should be set correctly");
    }

    function testDeploymentSetsOwnerCorrectly() public {
        assertEq(timer.owner(), owner, "Owner should be set correctly");
    }

    function testDeploymentRevertsIfTimerGovernanceIsZero() public {
        vm.startPrank(owner);
        vm.expectRevert(ZeroAddress.selector);
        new GovernanceUpgradeTimer(initialDelay, maxAdditionalDelay, address(0), owner);
        vm.stopPrank();
    }

    /* ========== Access Control Tests ========== */

    function testOnlyTimerGovernanceCanStartTimer() public {
        // Attempt to start timer as TIMER_GOVERNANCE
        vm.startPrank(timerGovernance);
        vm.expectEmit(true, true, false, true);
        emit TimerStarted(block.timestamp + initialDelay, block.timestamp + initialDelay + maxAdditionalDelay);
        timer.startTimer();
        vm.stopPrank();

        // Attempt to start timer as non-TIMER_GOVERNANCE
        vm.startPrank(nonAdmin);
        vm.expectRevert(CallerNotTimerAdmin.selector);
        timer.startTimer();
        vm.stopPrank();
    }

    function testOnlyOwnerCanChangeDeadline() public {
        // Start the timer first
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        uint256 newDeadline = timer.deadline() + 500;

        // Attempt to change deadline as owner
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit DeadlineChanged(newDeadline);
        timer.changeDeadline(newDeadline);
        vm.stopPrank();

        // Attempt to change deadline as non-owner
        vm.startPrank(nonAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        timer.changeDeadline(newDeadline + 100);
        vm.stopPrank();
    }

    /* ========== Functionality Tests ========== */

    function testStartTimerSetsDeadlineAndMaxDeadlineCorrectly() public {
        uint256 currentBlockTimestamp = block.timestamp;

        vm.startPrank(timerGovernance);
        vm.expectEmit(true, true, false, true);
        emit TimerStarted(
            currentBlockTimestamp + initialDelay,
            currentBlockTimestamp + initialDelay + maxAdditionalDelay
        );
        timer.startTimer();
        vm.stopPrank();

        assertEq(timer.deadline(), currentBlockTimestamp + initialDelay, "Deadline should be set correctly");
        assertEq(
            timer.maxDeadline(),
            currentBlockTimestamp + initialDelay + maxAdditionalDelay,
            "MaxDeadline should be set correctly"
        );
    }

    function testStartTimerCanNotBeCalledMultipleTimesByTimerGovernance() public {
        uint256 firstBlockTimestamp = block.timestamp;

        // First timer start
        vm.startPrank(timerGovernance);
        vm.expectEmit(true, true, false, true);
        emit TimerStarted(firstBlockTimestamp + initialDelay, firstBlockTimestamp + initialDelay + maxAdditionalDelay);
        timer.startTimer();
        vm.stopPrank();

        // Second timer start
        vm.startPrank(timerGovernance);
        vm.expectRevert(TimerAlreadyStarted.selector);
        timer.startTimer();
        vm.stopPrank();
    }

    function testCheckDeadlineRevertsIfDeadlineNotPassed() public {
        // Start the timer
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        // Attempt to check deadline before it has passed
        vm.expectRevert(DeadlineNotYetPassed.selector);
        timer.checkDeadline();
    }

    function testCheckDeadlineDoesNotRevertIfDeadlinePassed() public {
        // Start the timer
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        // Advance time past the deadline
        vm.warp(timer.deadline() + 1);

        // Check deadline should not revert
        timer.checkDeadline();
    }

    function testChangeDeadlineRevertsIfNewDeadlineNotGreater() public {
        // Start the timer
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        uint256 originalDeadline = timer.deadline();
        uint256 invalidNewDeadline = originalDeadline - 100;

        // Attempt to change deadline to a value not greater than current
        vm.startPrank(owner);
        vm.expectRevert(NewDeadlineNotGreaterThanCurrent.selector);
        timer.changeDeadline(invalidNewDeadline);
        vm.stopPrank();
    }

    function testChangeDeadlineRevertsIfNewDeadlineExceedsMaxDeadline() public {
        // Start the timer
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        uint256 maxDeadline = timer.maxDeadline();
        uint256 invalidNewDeadline = maxDeadline + 1;

        // Attempt to change deadline to exceed maxDeadline
        vm.startPrank(owner);
        vm.expectRevert(NewDeadlineExceedsMaxDeadline.selector);
        timer.changeDeadline(invalidNewDeadline);
        vm.stopPrank();
    }

    /* ========== Edge Case Tests ========== */

    function testChangeDeadlineToMaxDeadline() public {
        // Start the timer
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        uint256 maxDeadline = timer.maxDeadline();

        // Change deadline to maxDeadline
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit DeadlineChanged(maxDeadline);
        timer.changeDeadline(maxDeadline);
        vm.stopPrank();

        assertEq(timer.deadline(), maxDeadline, "Deadline should be set to maxDeadline");
    }

    function testChangeDeadlineRevertsIfNewDeadlineEqualsCurrent() public {
        // Start the timer
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        uint256 currentDeadline = timer.deadline();

        // Attempt to change deadline to the current deadline
        vm.startPrank(owner);
        vm.expectRevert(NewDeadlineNotGreaterThanCurrent.selector);
        timer.changeDeadline(currentDeadline);
        vm.stopPrank();
    }

    /* ========== Unauthorized Function Calls ========== */

    function testNonTimerGovernanceCannotStartTimer() public {
        vm.startPrank(owner);
        vm.expectRevert(CallerNotTimerAdmin.selector);
        timer.startTimer();
        vm.stopPrank();
    }

    function testNonOwnerCannotChangeDeadline() public {
        // Start the timer first
        vm.startPrank(timerGovernance);
        timer.startTimer();
        vm.stopPrank();

        uint256 newDeadline = timer.deadline() + 500;

        vm.startPrank(nonAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        timer.changeDeadline(newDeadline);
        vm.stopPrank();
    }
}
