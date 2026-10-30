// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {
    L1_BLOCK_HASH_IMPORT_ID,
    L1SLOAD_ANCHOR_BLOCK_HASH_SLOT,
    L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT,
    L1SLOAD_ANCHOR_TIMESTAMP_SLOT
} from "contracts/common/Config.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {L2_BOOTLOADER_ADDRESS, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadMockUtils} from "./L1SloadMockUtils.sol";

/// @notice Anchor imports through `L2InteropRootStorage`. See {protocol-docs/l1sload.md#anchors}.
contract L2InteropRootStorageL1AnchorTest is Test {
    L2InteropRootStorage internal rootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    function setUp() public {
        L1SloadMockUtils.install();
    }

    /// @dev ZKsync OS reads the block hash and timestamp slots directly, so they must not move.
    function test_l1AnchorSlots_constantsMatchDerivation() public pure {
        assertEq(
            L1SLOAD_ANCHOR_BLOCK_HASH_SLOT,
            bytes32(uint256(keccak256("zksync.l2-interop-root-storage.l1-anchor-block-hash")) - 1)
        );
        assertEq(
            L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT,
            bytes32(uint256(keccak256("zksync.l2-interop-root-storage.l1-anchor-block-number")) - 1)
        );
        assertEq(
            L1SLOAD_ANCHOR_TIMESTAMP_SLOT,
            bytes32(uint256(keccak256("zksync.l2-interop-root-storage.l1-anchor-timestamp")) - 1)
        );
    }

    /// @dev The import moves the anchor and emits both events; nothing is stored as a message root.
    function test_importMovesTheAnchor() public {
        bytes32 blockHash = keccak256("block 100");
        vm.expectEmit(L2_INTEROP_ROOT_STORAGE_ADDR);
        emit IL2InteropRootStorage.L1AnchorImported(100, blockHash, 1_000);
        vm.expectEmit(L2_INTEROP_ROOT_STORAGE_ADDR);
        emit IL2InteropRootStorage.InteropRootAdded(L1_BLOCK_HASH_IMPORT_ID, 100, 1_000, _sides(blockHash));
        vm.recordLogs();
        L1SloadMockUtils.importAnchor(100, blockHash, 1_000);

        assertEq(vm.getRecordedLogs().length, 2);
        _assertAnchor(100, blockHash, 1_000);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT), blockHash);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_TIMESTAMP_SLOT), bytes32(uint256(1_000)));
        assertEq(rootStorage.interopRoots(L1_BLOCK_HASH_IMPORT_ID, 100).timestamp, 0);
        assertEq(rootStorage.latestInteropRootTimestamp(L1_BLOCK_HASH_IMPORT_ID), 0);
    }

    /// @dev A stale import doesn't revert and leaves the anchor as it is, but still emits `InteropRootAdded`: ZKsync OS
    /// adds the root to the batch's dependency roots from it, and the server sends every imported root to L1.
    function test_staleImportEmitsTheRootAndKeepsTheAnchor() public {
        bytes32 anchorHash = keccak256("block 100");
        L1SloadMockUtils.importAnchor(100, anchorHash, 1_000);
        bytes32 staleHash = keccak256("block 99");

        vm.expectEmit(L2_INTEROP_ROOT_STORAGE_ADDR);
        emit IL2InteropRootStorage.InteropRootAdded(L1_BLOCK_HASH_IMPORT_ID, 99, 990, _sides(staleHash));
        vm.recordLogs();
        L1SloadMockUtils.importAnchor(99, staleHash, 990);

        assertEq(vm.getRecordedLogs().length, 1, "no L1AnchorImported");
        _assertAnchor(100, anchorHash, 1_000);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT), anchorHash);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_TIMESTAMP_SLOT), bytes32(uint256(1_000)));
    }

    /// @dev The anchor only moves to a higher block, and every import emits its root.
    function testFuzz_anchorOnlyMovesForward(uint64[4] memory _blockNumbers) public {
        uint256 highest;
        bytes32 highestHash;
        uint256 highestTimestamp;
        for (uint256 i = 0; i < _blockNumbers.length; ++i) {
            uint256 blockNumber = _blockNumbers[i];
            bytes32 blockHash = keccak256(abi.encode(blockNumber));
            vm.recordLogs();
            L1SloadMockUtils.importAnchor(blockNumber, blockHash, 1_000 + i);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (blockNumber > highest) {
                (highest, highestHash, highestTimestamp) = (blockNumber, blockHash, 1_000 + i);
                assertEq(logs.length, 2);
            } else {
                assertEq(logs.length, 1);
            }
            assertEq(logs[logs.length - 1].topics[0], IL2InteropRootStorage.InteropRootAdded.selector);
            assertEq(logs[logs.length - 1].topics[2], bytes32(blockNumber));
            _assertAnchor(highest, highestHash, highestTimestamp);
        }
    }

    /// @dev The server imports roots in batches: a stale anchor among them doesn't revert the batch.
    function test_batchWithAStaleAnchor() public {
        L1SloadMockUtils.importAnchor(100, keccak256("block 100"), 1_000);

        InteropRoot[] memory roots = new InteropRoot[](3);
        roots[0] = L1SloadMockUtils.anchorRoot(99, keccak256("block 99"), 990);
        roots[1] = L1SloadMockUtils.anchorRoot(101, keccak256("block 101"), 1_010);
        roots[2] = L1SloadMockUtils.anchorRoot(7, keccak256("root"), 1_005);
        roots[2].chainId = 320;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addInteropRootsInBatch(roots);

        _assertAnchor(101, keccak256("block 101"), 1_010);
        assertEq(rootStorage.interopRoots(320, 7).root, keccak256("root"));
    }

    /// @dev The checks every import passes still apply.
    function test_revertWhen_anchorHashIsZero() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(MessageRootIsZero.selector);
        rootStorage.addSingleInteropRoot(L1SloadMockUtils.anchorRoot(100, bytes32(0), 1_000));
    }

    function _sides(bytes32 _root) internal pure returns (bytes32[] memory sides) {
        sides = new bytes32[](1);
        sides[0] = _root;
    }

    function _assertAnchor(uint256 _blockNumber, bytes32 _blockHash, uint256 _timestamp) internal view {
        (uint256 blockNumber, bytes32 blockHash, uint256 timestamp) = rootStorage.l1Anchor();
        assertEq(blockNumber, _blockNumber);
        assertEq(blockHash, _blockHash);
        assertEq(timestamp, _timestamp);
    }
}
