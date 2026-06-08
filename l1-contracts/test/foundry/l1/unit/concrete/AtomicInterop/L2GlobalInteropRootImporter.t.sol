// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2GlobalInteropRootImporter} from "contracts/atomic-interop/L2GlobalInteropRootImporter.sol";
import {ImporterRootMismatch, ImporterZeroRoot} from "contracts/atomic-interop/AtomicInteropErrors.sol";

/// @notice Unit tests for the L2 global-root importer. `importGlobalRoot` is a TEMPORARY
/// permissionless stub (anyone may import), so these tests import from arbitrary callers.
contract L2GlobalInteropRootImporterTest is Test {
    L2GlobalInteropRootImporter internal importer;
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        importer = new L2GlobalInteropRootImporter();
    }

    function test_importGlobalRoot_storesAndTracks() public {
        vm.prank(anyone);
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        importer.importGlobalRoot(200, 3000, keccak256("g2"));

        assertEq(importer.globalRootAt(100), keccak256("g1"));
        assertEq(importer.timestampAt(100), 1000);
        assertTrue(importer.isImported(100));
        assertEq(importer.importedCount(), 2);
        assertEq(importer.importedBlockAt(0), 100);
        assertEq(importer.importedBlockAt(1), 200);
    }

    function test_importGlobalRoot_idempotentSameRoot() public {
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        // Re-import same root for same block: no-op, no extra entry.
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        assertEq(importer.importedCount(), 1);
    }

    function test_importGlobalRoot_revertsOnConflict() public {
        importer.importGlobalRoot(100, 1000, keccak256("g1"));
        vm.expectRevert(
            abi.encodeWithSelector(ImporterRootMismatch.selector, 100, keccak256("g1"), keccak256("other"))
        );
        importer.importGlobalRoot(100, 1000, keccak256("other"));
    }

    function test_importGlobalRoot_revertsOnZeroRoot() public {
        vm.expectRevert(ImporterZeroRoot.selector);
        importer.importGlobalRoot(100, 1000, bytes32(0));
    }
}
