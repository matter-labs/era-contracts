// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";

import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {
    L1_BLOCK_HASH_IMPORT_ID,
    L1SLOAD_ANCHOR_BLOCK_HASH_SLOT,
    L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT
} from "contracts/common/Config.sol";
import {InteropRootAlreadyExists} from "contracts/interop/InteropErrors.sol";
import {L2_BOOTLOADER_ADDRESS, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice Anchor imports through `L2InteropRootStorage`. See {protocol-docs/l1sload.md#anchors}.
contract L2InteropRootStorageL1AnchorTest is L1SloadSharedTest {
    uint256 internal constant BLOCK_1 = 100;
    uint256 internal constant BLOCK_2 = 200;
    uint256 internal constant TIMESTAMP_1 = 1_700_000_100;
    uint256 internal constant TIMESTAMP_2 = 1_700_000_200;
    bytes32 internal constant HASH_1 = keccak256("l1-block-100");
    bytes32 internal constant HASH_2 = keccak256("l1-block-200");

    /// @dev The slots ZKsync OS reads; the hash slot's value is fixed by the OS.
    function test_anchorSlotsMatchTheOS() public pure {
        assertEq(L1SLOAD_ANCHOR_BLOCK_HASH_SLOT, 0x142c4a6779611c44dc597e02ef1171577327f02356cebd6f373cfaa886831283);
        assertEq(L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT, keccak256("zksync-os.l1sload.anchor.block-number"));
    }

    function test_noAnchorBeforeTheFirstImport() public view {
        assertEq(rootStorage.l1AnchorBlockHash(), bytes32(0));
        assertEq(rootStorage.l1AnchorBlockNumber(), 0);
    }

    /// @dev The import stores the anchor as an ordinary root, emits exactly one side (the block hash, which the
    /// OS event hook requires), and moves the anchor slots that the OS reads.
    function test_importSetsAnchorAndEmitsOneSide() public {
        vm.recordLogs();
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "only InteropRootAdded is emitted");
        assertEq(logs[0].emitter, L2_INTEROP_ROOT_STORAGE_ADDR);
        assertEq(logs[0].topics[0], IL2InteropRootStorage.InteropRootAdded.selector);
        assertEq(uint256(logs[0].topics[1]), L1_BLOCK_HASH_IMPORT_ID);
        assertEq(uint256(logs[0].topics[2]), BLOCK_1);
        (uint256 timestamp, bytes32[] memory sides) = abi.decode(logs[0].data, (uint256, bytes32[]));
        assertEq(timestamp, TIMESTAMP_1);
        assertEq(sides.length, 1, "exactly one side");
        assertEq(sides[0], HASH_1);

        StoredInteropRoot memory stored = rootStorage.interopRoots(L1_BLOCK_HASH_IMPORT_ID, BLOCK_1);
        assertEq(stored.root, HASH_1);
        assertEq(stored.timestamp, TIMESTAMP_1);
        assertEq(rootStorage.latestInteropRootTimestamp(L1_BLOCK_HASH_IMPORT_ID), TIMESTAMP_1);

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_1);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_1);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT), HASH_1, "OS-read slot");
        assertEq(uint256(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT)), BLOCK_1);
    }

    function test_newerImportMovesAnchor() public {
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);
        _importL1Anchor(BLOCK_2, HASH_2, TIMESTAMP_2);

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_2);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_2);
    }

    /// @dev Imports need not arrive in block order; an older one is stored but never moves the anchor back.
    function test_olderImportKeepsAnchor() public {
        _importL1Anchor(BLOCK_2, HASH_2, TIMESTAMP_2);
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_2);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_2);
        assertEq(rootStorage.interopRoots(L1_BLOCK_HASH_IMPORT_ID, BLOCK_1).root, HASH_1, "still stored");
    }

    function test_revertWhen_anchorImportedTwice() public {
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(InteropRootAlreadyExists.selector);
        rootStorage.addSingleInteropRoot(_anchorRoot(BLOCK_1, HASH_2, TIMESTAMP_1));
    }

    /// @dev A root of a real chain at a higher number than the anchor is not an anchor.
    function test_otherChainRootsDoNotMoveAnchor() public {
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);

        InteropRoot memory chainRoot = _anchorRoot(BLOCK_2, HASH_2, TIMESTAMP_2);
        chainRoot.chainId = L1_CHAIN_ID;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(chainRoot);

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_1);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_1);
    }

    function testFuzz_anchorIsTheHighestImportedBlock(uint64[4] memory _blockNumbers) public {
        uint256 highest;
        bytes32 highestHash;
        for (uint256 i = 0; i < _blockNumbers.length; ++i) {
            uint256 blockNumber = uint256(_blockNumbers[i]) + 1;
            if (rootStorage.interopRoots(L1_BLOCK_HASH_IMPORT_ID, blockNumber).root != bytes32(0)) {
                continue;
            }
            bytes32 blockHash = keccak256(abi.encode(blockNumber));
            _importL1Anchor(blockNumber, blockHash, TIMESTAMP_1 + i);
            if (blockNumber > highest) {
                highest = blockNumber;
                highestHash = blockHash;
            }
        }
        assertEq(rootStorage.l1AnchorBlockNumber(), highest);
        assertEq(rootStorage.l1AnchorBlockHash(), highestHash);
    }
}
