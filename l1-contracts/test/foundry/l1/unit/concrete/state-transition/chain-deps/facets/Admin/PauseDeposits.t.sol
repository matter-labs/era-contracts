// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {DepositsAlreadyPaused, NotL1} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET, PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";

contract PauseDepositsTest is AdminTest {
    event DepositsPaused(uint256 chainId, uint256 pausedDepositsTimestamp);

    // The `pausedDepositsTimestamp` sits at slot 62 of ZKChainStorage
    bytes32 pausedDepositsTimestampSlot = bytes32(uint256(62));

    function setUp() public override {
        // Timestamp needs to be late enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);
        super.setUp();
    }

    function test_revertWhen_calledByNonAdminOrChainTypeManager() public {
        address nonAdminOrChainTypeManager = makeAddr("nonAdminOrChainTypeManager");

        vm.startPrank(nonAdminOrChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdminOrChainTypeManager));
        adminFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_revertWhen_notL1() public {
        uint256 fakeChainId = 1337;
        vm.chainId(fakeChainId);
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, fakeChainId));
        adminFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_successfulCall_newChain() public {
        uint256 chainId = utilsFacet.util_getChainId();
        uint256 expectedTimestamp = block.timestamp - PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET;
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit DepositsPaused(chainId, expectedTimestamp);
        adminFacet.pauseDepositsBeforeInitiatingMigration();

        // Read storage to check that the recorded timestamp matches the event
        uint256 pausedDepositsTimestamp = uint256(vm.load(address(adminFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, expectedTimestamp);
    }

    function test_successfulCall_existingChain() public {
        uint256 chainId = utilsFacet.util_getChainId();
        address admin = utilsFacet.util_getAdmin();

        // The priorityTree sits at slot 51 of ZKChainStorage
        bytes32 slot = bytes32(uint256(51));
        // Fake a deposit by extending the priority tree so `getTotalPriorityTxs` returns non-zero
        vm.store(address(adminFacet), slot, bytes32(uint256(1)));

        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit DepositsPaused(chainId, block.timestamp);
        adminFacet.pauseDepositsBeforeInitiatingMigration();

        // Read storage to check that the recorded timestamp matches the event
        uint256 pausedDepositsTimestamp = uint256(vm.load(address(adminFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, block.timestamp);
    }

    function test_revertWhen_depositsAlreadyPaused() public {
        address admin = utilsFacet.util_getAdmin();
        // Pause deposits, works
        vm.startPrank(admin);
        adminFacet.pauseDepositsBeforeInitiatingMigration();
        // Try to pause them again, reverts
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(DepositsAlreadyPaused.selector));
        adminFacet.pauseDepositsBeforeInitiatingMigration();
    }
}
