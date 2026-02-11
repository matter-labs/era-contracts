// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IChainAssetHandler, MigrationInterval} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {MigrationNumberMismatch, MigrationIntervalNotSet, MigrationIntervalInvalid, HistoricalSettlementLayerMismatch} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

contract ChainAssetHandlerSettlementLayerTest is Test {
    L1ChainAssetHandler chainAssetHandler;

    address owner = makeAddr("owner");
    address bridgehub = makeAddr("bridgehub");
    address messageRoot = makeAddr("messageRoot");

    uint256 constant LEGACY_GW_CHAIN_ID = 505;
    uint256 constant CHAIN_A = 100;
    uint256 constant L1_CHAIN_ID = 1; // block.chainid in test

    function setUp() public {
        // Mock bridgehub.messageRoot() so the chain asset handler can query it dynamically
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.messageRoot.selector), abi.encode(messageRoot));
        // Mock the messageRoot ERA_GATEWAY_CHAIN_ID
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageRoot.ERA_GATEWAY_CHAIN_ID.selector),
            abi.encode(LEGACY_GW_CHAIN_ID)
        );

        chainAssetHandler = new L1ChainAssetHandler(owner, bridgehub);
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(address(0)));
        vm.prank(owner);
        chainAssetHandler.setAddresses();
    }

    /*//////////////////////////////////////////////////////////////
                    setHistoricalMigrationInterval
    //////////////////////////////////////////////////////////////*/

    function test_setHistoricalMigrationInterval_success() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.prank(owner);
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);

        MigrationInterval memory stored = chainAssetHandler.migrationInterval(CHAIN_A, 0);
        assertEq(stored.migrateToGWBatchNumber, 10);
        assertEq(stored.migrateFromGWBatchNumber, 50);
        assertEq(stored.settlementLayerChainId, LEGACY_GW_CHAIN_ID);
        assertFalse(stored.isActive);
    }

    function test_setHistoricalMigrationInterval_revertmigrateFromGWBatchNumberZero() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 0, // invalid: from must be > to
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalInvalid.selector));
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertNotOwner() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertMigrationNumberNotZero() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MigrationNumberMismatch.selector, 0, 1));
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 1, interval);
    }

    function test_setHistoricalMigrationInterval_revertNotSet() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: true
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalNotSet.selector));
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertWrongSettlementLayer() public {
        uint256 wrongSL = 999;
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: wrongSL,
            isActive: false
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HistoricalSettlementLayerMismatch.selector, LEGACY_GW_CHAIN_ID, wrongSL)
        );
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);
    }

    function test_setHistoricalMigrationInterval_migrateToGWBatchNumberZero() public {
        // migrateToGWBatchNumber == 0 is valid: the chain migrated before any batches were committed
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 0,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.prank(owner);
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);

        MigrationInterval memory stored = chainAssetHandler.migrationInterval(CHAIN_A, 0);
        assertEq(stored.migrateToGWBatchNumber, 0);
        assertEq(stored.migrateFromGWBatchNumber, 50);
        assertFalse(stored.isActive);
    }

    function test_setHistoricalMigrationInterval_revertmigrateFromGWBatchNumberNotGreaterThanTo() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 50,
            migrateFromGWBatchNumber: 30, // invalid: from < to
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalInvalid.selector));
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertmigrateFromGWBatchNumberEqualTo() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 50,
            migrateFromGWBatchNumber: 50, // invalid: from == to
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalInvalid.selector));
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);
    }

    /*//////////////////////////////////////////////////////////////
                    isValidSettlementLayer
    //////////////////////////////////////////////////////////////*/

    function test_isValidSettlementLayer_noMigrationAllBatchesOnL1() public view {
        // Chain has no migration, all batches should be on L1
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 1, block.chainid));
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 100, block.chainid));

        // Claiming a different settlement layer should return false
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 1, LEGACY_GW_CHAIN_ID));
    }

    function test_isValidSettlementLayer_historicalMigrationBatchBeforeMigration() public {
        // Set up historical migration: chain was on GW from batch 10 to batch 50
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });
        vm.prank(owner);
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);

        // Batch 5 (before migration to GW) should be on L1
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 5, block.chainid));
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 5, LEGACY_GW_CHAIN_ID));

        // Batch 10 (the boundary, still on L1) should be on L1
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 10, block.chainid));
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 10, LEGACY_GW_CHAIN_ID));
    }

    function test_isValidSettlementLayer_historicalMigrationBatchDuringMigration() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });
        vm.prank(owner);
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);

        // Batch 11 (first batch on GW) should be on GW
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 11, LEGACY_GW_CHAIN_ID));
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 11, block.chainid));

        // Batch 30 (middle of migration) should be on GW
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 30, LEGACY_GW_CHAIN_ID));
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 30, block.chainid));

        // Batch 50 (boundary, last batch on GW) should be on GW
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 50, LEGACY_GW_CHAIN_ID));
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 50, block.chainid));
    }

    function test_isValidSettlementLayer_historicalMigrationBatchAfterReturn() public {
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });
        vm.prank(owner);
        chainAssetHandler.setHistoricalMigrationInterval(CHAIN_A, 0, interval);

        // Batch 51 (after return to L1) should be on L1
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 51, block.chainid));
        assertFalse(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 51, LEGACY_GW_CHAIN_ID));

        // Batch 100 (well after return) should be on L1
        assertTrue(chainAssetHandler.isValidSettlementLayer(CHAIN_A, 100, block.chainid));
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
