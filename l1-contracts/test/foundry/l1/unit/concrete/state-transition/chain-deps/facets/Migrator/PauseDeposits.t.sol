// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    DepositsAlreadyPaused,
    NotL1,
    TotalPriorityTxsIsZero
} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";

contract PauseDepositsTest is MigratorTest {
    event DepositsPaused(uint256 chainId, uint256 pausedDepositsTimestamp);

    // The `pausedDepositsTimestamp` sits at slot 62 of ZKChainStorage
    bytes32 pausedDepositsTimestampSlot = bytes32(uint256(62));

    function setUp() public override {
        // Avoid block.timestamp == 0 to keep paused-deposits sentinel semantics stable in tests.
        vm.warp(1);
        super.setUp();
    }

    function test_revertWhen_calledByNonAdminOrChainTypeManager() public {
        address nonAdminOrChainTypeManager = makeAddr("nonAdminOrChainTypeManager");

        vm.startPrank(nonAdminOrChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdminOrChainTypeManager));
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_revertWhen_notL1() public {
        uint256 fakeChainId = 1337;
        vm.chainId(fakeChainId);
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, fakeChainId));
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_successfulCall_newChain() public {
        uint256 chainId = utilsFacet.util_getChainId();
        uint256 expectedTimestamp = block.timestamp;
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit DepositsPaused(chainId, expectedTimestamp);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();

        // Read storage to check that the recorded timestamp matches the event
        uint256 pausedDepositsTimestamp = uint256(vm.load(address(migratorFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, expectedTimestamp);
    }

    function test_successfulCall_existingChain() public {
        uint256 chainId = utilsFacet.util_getChainId();
        address admin = utilsFacet.util_getAdmin();

        // The priorityTree sits at slot 51 of ZKChainStorage
        bytes32 slot = bytes32(uint256(51));
        // Fake a deposit by extending the priority tree so `getTotalPriorityTxs` returns non-zero
        vm.store(address(migratorFacet), slot, bytes32(uint256(1)));

        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit DepositsPaused(chainId, block.timestamp);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();

        // Read storage to check that the recorded timestamp matches the event
        uint256 pausedDepositsTimestamp = uint256(vm.load(address(migratorFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, block.timestamp);
    }

    function test_revertWhen_depositsAlreadyPaused() public {
        address admin = utilsFacet.util_getAdmin();
        // Pause deposits, works
        vm.startPrank(admin);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
        // Try to pause them again, reverts
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(DepositsAlreadyPaused.selector));
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_revertWhen_settlementLayerSet_andTotalPriorityTxsIsZero() public {
        // Set up: settlementLayer is non-zero, but totalPriorityTxs is 0
        // This should trigger the TotalPriorityTxsIsZero error on line 340
        address admin = utilsFacet.util_getAdmin();
        address settlementLayer = makeAddr("settlementLayer");
        address assetTracker = makeAddr("assetTracker");

        utilsFacet.util_setSettlementLayer(settlementLayer);
        utilsFacet.util_setAssetTracker(assetTracker);

        // Priority tree is at slot 51, nextLeafIndex (totalPriorityTxs) is within the tree struct
        // With default initialization, totalPriorityTxs should be 0

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(TotalPriorityTxsIsZero.selector));
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_retry_resendsCrossChainPauseMsg_withoutTouchingL1Flag() public {
        // Setup: L1 already paused (pausedDepositsTimestamp != 0) AND chain on a remote SL.
        // This is the "the original cross-chain pause msg failed to land on Gateway" recovery
        // path: calling pauseDepositsBeforeInitiatingMigration again should re-send the msg
        // using L1's existing pausedDepositsTimestamp, without overwriting it and without
        // emitting a new DepositsPaused event.
        uint256 chainId = utilsFacet.util_getChainId();
        address admin = utilsFacet.util_getAdmin();
        address settlementLayer = makeAddr("settlementLayer");
        address assetTracker = makeAddr("assetTracker");

        // Warp forward so block.timestamp is comfortably > 0 and we can pick an "earlier" pause.
        vm.warp(1000);
        // Pretend admin previously paused (set pausedDepositsTimestamp directly to a known value).
        uint256 originalPauseTimestamp = block.timestamp - 100;
        vm.store(address(migratorFacet), pausedDepositsTimestampSlot, bytes32(originalPauseTimestamp));

        utilsFacet.util_setSettlementLayer(settlementLayer);
        utilsFacet.util_setAssetTracker(assetTracker);

        // Expect the cross-chain pause msg to be re-sent.
        vm.expectCall(
            assetTracker,
            abi.encodeWithSelector(IL1AssetTracker.requestPauseDepositsForChainOnGateway.selector, chainId)
        );
        // Mock it so the call doesn't revert.
        vm.mockCall(
            assetTracker,
            abi.encodeWithSelector(IL1AssetTracker.requestPauseDepositsForChainOnGateway.selector, chainId),
            abi.encode()
        );

        vm.startPrank(admin);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();

        // L1's pausedDepositsTimestamp must be untouched: same value as before the retry.
        uint256 pausedDepositsTimestampAfter = uint256(
            vm.load(address(migratorFacet), pausedDepositsTimestampSlot)
        );
        assertEq(pausedDepositsTimestampAfter, originalPauseTimestamp);
    }

    function test_successfulCall_settlementLayerSet_withPriorityTxs() public {
        // Set up: settlementLayer is non-zero, totalPriorityTxs > 0
        // This should call requestPauseDepositsForChainOnGateway (line 341)
        uint256 chainId = utilsFacet.util_getChainId();
        address admin = utilsFacet.util_getAdmin();
        address settlementLayer = makeAddr("settlementLayer");
        address assetTracker = makeAddr("assetTracker");

        utilsFacet.util_setSettlementLayer(settlementLayer);
        utilsFacet.util_setAssetTracker(assetTracker);

        // Fake a deposit by extending the priority tree so `getTotalPriorityTxs` returns non-zero
        // The priorityTree sits at slot 51 of ZKChainStorage
        bytes32 slot = bytes32(uint256(51));
        vm.store(address(migratorFacet), slot, bytes32(uint256(1)));

        // Mock the requestPauseDepositsForChainOnGateway call
        vm.mockCall(
            assetTracker,
            abi.encodeWithSelector(IL1AssetTracker.requestPauseDepositsForChainOnGateway.selector, chainId),
            abi.encode()
        );

        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit DepositsPaused(chainId, block.timestamp);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();

        // Read storage to check that the recorded timestamp matches the event
        uint256 pausedDepositsTimestamp = uint256(vm.load(address(migratorFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, block.timestamp);
    }
}
