// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {DepositsNotPaused, MigrationInProgress} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";

contract UnpauseDepositsTest is MigratorTest {
    event DepositsUnpaused(uint256 chainId);

    // The `pausedDepositsTimestamp` sits at slot 62 of ZKChainStorage
    bytes32 pausedDepositsTimestampSlot = bytes32(uint256(62));

    function setUp() public override {
        // Timestamp needs to be late enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);
        super.setUp();
    }

    function _pauseDeposits() internal {
        // We first need to pause deposits before we get to unpause them
        address admin = utilsFacet.util_getAdmin();
        vm.startPrank(admin);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
    }

    function test_revertWhen_calledByNonAdmin() public {
        _pauseDeposits();
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        migratorFacet.unpauseDeposits();
    }

    function test_revertWhen_depositsNotPaused() public {
        // Call reverts when deposits if deposits were not paused
        address admin = utilsFacet.util_getAdmin();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(DepositsNotPaused.selector));
        migratorFacet.unpauseDeposits();

        // The priorityTree sits at slot 51 of ZKChainStorage
        bytes32 slot = bytes32(uint256(51));
        // Fake a deposit by extending the priority tree so `getTotalPriorityTxs` returns non-zero
        vm.store(address(migratorFacet), slot, bytes32(uint256(1)));
        // The `pausedDepositsTimestamp` will therefore be set to the current `block.timestamp`
        _pauseDeposits();

        // Call reverts before the paused window comes into effect
        vm.expectRevert(abi.encodeWithSelector(DepositsNotPaused.selector));
        migratorFacet.unpauseDeposits();
        // Call also reverts after the paused window ends
        vm.warp(block.timestamp + PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(DepositsNotPaused.selector));
        migratorFacet.unpauseDeposits();
    }

    function test_revertWhen_migrationInProgress() public {
        _pauseDeposits();
        uint256 chainId = utilsFacet.util_getChainId();
        address admin = utilsFacet.util_getAdmin();
        address bridgehub = utilsFacet.util_getBridgehub();
        address mockChainAssetHandler = makeAddr("mockChainAssetHandler");

        // We need to fake a migration in progress
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(mockChainAssetHandler)
        );
        vm.mockCall(
            mockChainAssetHandler,
            abi.encodeWithSelector(IL1ChainAssetHandler.isMigrationInProgress.selector, chainId),
            abi.encode(true)
        );

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(MigrationInProgress.selector));
        migratorFacet.unpauseDeposits();
    }

    function test_successfulCall() public {
        _pauseDeposits();
        uint256 chainId = utilsFacet.util_getChainId();
        address admin = utilsFacet.util_getAdmin();
        address bridgehub = utilsFacet.util_getBridgehub();
        address mockChainAssetHandler = makeAddr("mockChainAssetHandler");

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(mockChainAssetHandler)
        );
        vm.mockCall(
            mockChainAssetHandler,
            abi.encodeWithSelector(IL1ChainAssetHandler.isMigrationInProgress.selector, chainId),
            abi.encode(false)
        );

        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit DepositsUnpaused(chainId);
        migratorFacet.unpauseDeposits();

        // Read storage to check that the recorded timestamp is reset to 0
        uint256 pausedDepositsTimestamp = uint256(vm.load(address(migratorFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, 0);
    }
}
