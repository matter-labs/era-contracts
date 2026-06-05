// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2GlobalInteropRootImporter} from "contracts/atomic-interop/L2GlobalInteropRootImporter.sol";
import {
    ImporterAlreadyInitialized,
    ImporterNotSupplier,
    ImporterRootMismatch,
    ImporterZeroRoot,
    ImporterZeroSupplier
} from "contracts/atomic-interop/AtomicInteropErrors.sol";

contract L2GlobalInteropRootImporterTest is Test {
    L2GlobalInteropRootImporter internal importer;

    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        importer = new L2GlobalInteropRootImporter();
        importer.initialize(supplier);
    }

    function test_initialize_once() public {
        assertEq(importer.supplier(), supplier);
        vm.expectRevert(ImporterAlreadyInitialized.selector);
        importer.initialize(supplier);
    }

    function test_initialize_revertsOnZeroSupplier() public {
        L2GlobalInteropRootImporter fresh = new L2GlobalInteropRootImporter();
        vm.expectRevert(ImporterZeroSupplier.selector);
        fresh.initialize(address(0));
    }

    function test_importGlobalRoot_storesAndTracks() public {
        vm.prank(supplier);
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        vm.prank(supplier);
        importer.importGlobalRoot(200, 3000, keccak256("g2"));

        assertEq(importer.globalRootAt(100), keccak256("g1"));
        assertEq(importer.timestampAt(100), 1000);
        assertTrue(importer.isImported(100));
        assertEq(importer.importedCount(), 2);
        assertEq(importer.importedBlockAt(0), 100);
        assertEq(importer.importedBlockAt(1), 200);
    }

    function test_importGlobalRoot_idempotentSameRoot() public {
        vm.startPrank(supplier);
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        // Re-import same root for same block: no-op, no extra entry.
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        vm.stopPrank();
        assertEq(importer.importedCount(), 1);
    }

    function test_importGlobalRoot_revertsOnConflict() public {
        vm.startPrank(supplier);
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        vm.expectRevert(
            abi.encodeWithSelector(ImporterRootMismatch.selector, 100, keccak256("g1"), keccak256("other"))
        );
        importer.importGlobalRoot(100, 1000, keccak256("other"));
        vm.stopPrank();
    }

    function test_importGlobalRoot_onlySupplier() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ImporterNotSupplier.selector, stranger));
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
    }

    function test_importGlobalRoot_revertsOnZeroRoot() public {
        vm.prank(supplier);
        vm.expectRevert(ImporterZeroRoot.selector);
        importer.importGlobalRoot(100, 1000, bytes32(0));
    }
}
