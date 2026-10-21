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
import {InteropRootTimestampIsZero, L1AnchorNotNewer, SidesLengthNotOne} from "contracts/interop/InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
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

    /// @dev The import emits exactly one side (the block hash, which the OS event hook requires) and moves the anchor
    /// slots that the OS reads; nothing is stored as a root.
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

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_1);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_1);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT), HASH_1, "OS-read slot");
        assertEq(uint256(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT)), BLOCK_1);
    }

    /// @dev An anchor is not a message root, so nothing that reads roots sees it.
    function test_importStoresNoRoot() public {
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);

        StoredInteropRoot memory stored = rootStorage.interopRoots(L1_BLOCK_HASH_IMPORT_ID, BLOCK_1);
        assertEq(stored.root, bytes32(0));
        assertEq(stored.timestamp, 0);
        assertEq(rootStorage.latestInteropRootTimestamp(L1_BLOCK_HASH_IMPORT_ID), 0);
    }

    function test_newerImportMovesAnchor() public {
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);
        _importL1Anchor(BLOCK_2, HASH_2, TIMESTAMP_2);

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_2);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_2);
    }

    /// @dev The anchor never moves back: an older import reverts.
    function test_revertWhen_olderImport() public {
        _importL1Anchor(BLOCK_2, HASH_2, TIMESTAMP_2);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, BLOCK_1, BLOCK_2));
        rootStorage.addSingleInteropRoot(_anchorRoot(BLOCK_1, HASH_1, TIMESTAMP_1));

        assertEq(rootStorage.l1AnchorBlockHash(), HASH_2);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_2);
    }

    function test_revertWhen_anchorImportedTwice() public {
        _importL1Anchor(BLOCK_1, HASH_1, TIMESTAMP_1);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, BLOCK_1, BLOCK_1));
        rootStorage.addSingleInteropRoot(_anchorRoot(BLOCK_1, HASH_2, TIMESTAMP_1));
    }

    /// @dev Block 0 can't be anchored: zero means "no anchor".
    function test_revertWhen_blockZero() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, 0, 0));
        rootStorage.addSingleInteropRoot(_anchorRoot(0, HASH_1, TIMESTAMP_1));
    }

    /// @dev Several anchors in one batch import go through in increasing order; a decrease reverts the whole call.
    function test_batchImport() public {
        InteropRoot[] memory roots = new InteropRoot[](2);
        roots[0] = _anchorRoot(BLOCK_1, HASH_1, TIMESTAMP_1);
        roots[1] = _anchorRoot(BLOCK_2, HASH_2, TIMESTAMP_2);
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addInteropRootsInBatch(roots);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_2);

        (roots[0], roots[1]) = (
            _anchorRoot(BLOCK_2 + 2, HASH_2, TIMESTAMP_2),
            _anchorRoot(BLOCK_2 + 1, HASH_1, TIMESTAMP_2)
        );
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, BLOCK_2 + 1, BLOCK_2 + 2));
        rootStorage.addInteropRootsInBatch(roots);
        assertEq(rootStorage.l1AnchorBlockNumber(), BLOCK_2);
    }

    /// @dev The import's other checks still apply to anchors.
    function test_revertWhen_anchorIsMalformed() public {
        InteropRoot memory anchor = _anchorRoot(BLOCK_1, bytes32(0), TIMESTAMP_1);
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(MessageRootIsZero.selector);
        rootStorage.addSingleInteropRoot(anchor);

        anchor = _anchorRoot(BLOCK_1, HASH_1, 0);
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(InteropRootTimestampIsZero.selector);
        rootStorage.addSingleInteropRoot(anchor);

        anchor.timestamp = TIMESTAMP_1;
        anchor.sides = new bytes32[](2);
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(SidesLengthNotOne.selector);
        rootStorage.addSingleInteropRoot(anchor);

        assertEq(rootStorage.l1AnchorBlockNumber(), 0);
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
        assertEq(rootStorage.interopRoots(L1_CHAIN_ID, BLOCK_2).root, HASH_2, "stored as a root");
    }

    /// @dev Each import either moves the anchor to a strictly higher block or reverts and leaves it in place.
    function testFuzz_anchorOnlyMovesForward(uint64[4] memory _blockNumbers) public {
        uint256 highest;
        bytes32 highestHash;
        for (uint256 i = 0; i < _blockNumbers.length; ++i) {
            uint256 blockNumber = uint256(_blockNumbers[i]) + 1;
            bytes32 blockHash = keccak256(abi.encode(blockNumber));
            if (blockNumber > highest) {
                _importL1Anchor(blockNumber, blockHash, TIMESTAMP_1 + i);
                highest = blockNumber;
                highestHash = blockHash;
            } else {
                vm.prank(L2_BOOTLOADER_ADDRESS);
                vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, blockNumber, highest));
                rootStorage.addSingleInteropRoot(_anchorRoot(blockNumber, blockHash, TIMESTAMP_1 + i));
            }
            assertEq(rootStorage.l1AnchorBlockNumber(), highest);
            assertEq(rootStorage.l1AnchorBlockHash(), highestHash);
        }
    }
}
