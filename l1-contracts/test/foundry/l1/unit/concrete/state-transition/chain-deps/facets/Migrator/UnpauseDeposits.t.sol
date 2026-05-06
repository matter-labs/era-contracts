// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {DepositsNotPaused, MigrationInProgress} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {GW_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract UnpauseDepositsTest is MigratorTest {
    event DepositsUnpaused(uint256 chainId);

    // The `pausedDepositsTimestamp` sits at slot 62 of ZKChainStorage
    bytes32 pausedDepositsTimestampSlot = bytes32(uint256(62));

    function setUp() public override {
        // Avoid block.timestamp == 0 to keep paused-deposits sentinel semantics stable in tests.
        vm.warp(1);
        super.setUp();
    }

    function _pauseDeposits() internal {
        // We first need to pause deposits before we get to unpause them
        address admin = utilsFacet.util_getAdmin();
        vm.startPrank(admin);
        migratorFacet.pauseDepositsBeforeInitiatingMigration();
        vm.stopPrank();
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

    function test_unpauseDepositsOnGateway_RevertWhen_NotGatewayAssetTracker() public {
        _pauseDeposits();
        vm.chainId(block.chainid + 1);

        address notGatewayAssetTracker = makeAddr("notGatewayAssetTracker");
        vm.prank(notGatewayAssetTracker);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notGatewayAssetTracker));
        migratorFacet.unpauseDepositsOnGateway();
    }

    function test_unpauseDepositsOnGateway_RevertWhen_DepositsNotPaused() public {
        vm.chainId(block.chainid + 1);

        vm.prank(GW_ASSET_TRACKER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(DepositsNotPaused.selector));
        migratorFacet.unpauseDepositsOnGateway();
    }

    function test_unpauseDepositsOnGateway_Success() public {
        _pauseDeposits();
        uint256 chainId = utilsFacet.util_getChainId();

        vm.chainId(block.chainid + 1);
        vm.prank(GW_ASSET_TRACKER_ADDR);
        vm.expectEmit(true, false, false, false);
        emit DepositsUnpaused(chainId);
        migratorFacet.unpauseDepositsOnGateway();

        uint256 pausedDepositsTimestamp = uint256(vm.load(address(migratorFacet), pausedDepositsTimestampSlot));
        assertEq(pausedDepositsTimestamp, 0);
    }
}
